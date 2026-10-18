package com.tandem.app.ble

import android.util.Base64
import java.math.BigInteger
import java.security.*
import java.security.interfaces.ECPublicKey
import java.security.spec.*
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object TandemCrypto {

    private val KDF_SALT = "Tandem-v0.2-Salt".toByteArray(Charsets.UTF_8)
    private val KDF_INFO = "AES-256-GCM".toByteArray(Charsets.UTF_8)

    private var privateKey: PrivateKey? = null
    private var localRawPublicKey: ByteArray? = null
    private var sessionKey: SecretKey? = null
    var securityCode: String? = null
        private set

    val isEncrypted: Boolean
        get() = sessionKey != null

    init {
        resetKeypair()
    }

    fun resetKeypair() {
        try {
            val kpg = KeyPairGenerator.getInstance("EC")
            val ecSpec = ECGenParameterSpec("secp256r1")
            kpg.initialize(ecSpec)
            val kp = kpg.generateKeyPair()
            privateKey = kp.private
            val ecPub = kp.public as ECPublicKey
            localRawPublicKey = toRawBytes(ecPub)
            sessionKey = null
            securityCode = null
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    fun getLocalRawPublicKey(): ByteArray? {
        if (localRawPublicKey == null) resetKeypair()
        return localRawPublicKey
    }

    fun completeKeyExchange(peerRawPub: ByteArray): String {
        val myPriv = privateKey ?: throw IllegalStateException("Local private key not initialized")
        require(peerRawPub.size == 64) { "Expected 64-byte raw public key, received ${peerRawPub.size} bytes" }

        val peerPublicKey = fromRawBytes(peerRawPub)
        val keyAgreement = KeyAgreement.getInstance("ECDH")
        keyAgreement.init(myPriv)
        keyAgreement.doPhase(peerPublicKey, true)
        val sharedSecret = keyAgreement.generateSecret()

        val derivedKeyBytes = hkdfSha256(sharedSecret, KDF_SALT, KDF_INFO, 32)
        sessionKey = SecretKeySpec(derivedKeyBytes, "AES")

        val myPubRaw = localRawPublicKey ?: throw IllegalStateException("Local public key missing")
        val sas = computeSasCode(myPubRaw, peerRawPub)
        securityCode = sas
        return sas
    }

    fun encrypt(plaintext: String): String {
        val key = sessionKey ?: throw IllegalStateException("No active E2EE session key")
        val iv = ByteArray(12)
        SecureRandom().nextBytes(iv)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val spec = GCMParameterSpec(128, iv)
        cipher.init(Cipher.ENCRYPT_MODE, key, spec)

        val ciphertextWithTag = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(12 + ciphertextWithTag.size)
        System.arraycopy(iv, 0, combined, 0, 12)
        System.arraycopy(ciphertextWithTag, 0, combined, 12, ciphertextWithTag.size)

        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    fun decrypt(base64Ciphertext: String): String {
        val key = sessionKey ?: throw IllegalStateException("No active E2EE session key")
        val combined = Base64.decode(base64Ciphertext, Base64.DEFAULT)
        require(combined.size > 28) { "Ciphertext payload too short (${combined.size} bytes)" }

        val iv = ByteArray(12)
        System.arraycopy(combined, 0, iv, 0, 12)
        val ciphertextWithTag = ByteArray(combined.size - 12)
        System.arraycopy(combined, 12, ciphertextWithTag, 0, ciphertextWithTag.size)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val spec = GCMParameterSpec(128, iv)
        cipher.init(Cipher.DECRYPT_MODE, key, spec)

        val plaintextBytes = cipher.doFinal(ciphertextWithTag)
        return String(plaintextBytes, Charsets.UTF_8)
    }

    private fun computeSasCode(pubA: ByteArray, pubB: ByteArray): String {
        val compare = compareByteArrays(pubA, pubB)
        val (first, second) = if (compare <= 0) Pair(pubA, pubB) else Pair(pubB, pubA)

        val md = MessageDigest.getInstance("SHA-256")
        md.update(first)
        md.update(second)
        val digest = md.digest()

        val num = ((digest[0].toLong() and 0xFF) shl 24) or
                  ((digest[1].toLong() and 0xFF) shl 16) or
                  ((digest[2].toLong() and 0xFF) shl 8) or
                   (digest[3].toLong() and 0xFF)

        val code = (num % 1000000).toInt()
        return String.format("%03d-%03d", code / 1000, code % 1000)
    }

    private fun compareByteArrays(a: ByteArray, b: ByteArray): Int {
        val minLen = minOf(a.size, b.size)
        for (i in 0 until minLen) {
            val byteA = a[i].toInt() and 0xFF
            val byteB = b[i].toInt() and 0xFF
            if (byteA != byteB) return byteA - byteB
        }
        return a.size - b.size
    }

    private fun toRawBytes(pub: ECPublicKey): ByteArray {
        val x = toFixed32(pub.w.affineX)
        val y = toFixed32(pub.w.affineY)
        val raw = ByteArray(64)
        System.arraycopy(x, 0, raw, 0, 32)
        System.arraycopy(y, 0, raw, 32, 32)
        return raw
    }

    private fun fromRawBytes(raw: ByteArray): PublicKey {
        val xBytes = ByteArray(32)
        val yBytes = ByteArray(32)
        System.arraycopy(raw, 0, xBytes, 0, 32)
        System.arraycopy(raw, 32, yBytes, 0, 32)
        val x = BigInteger(1, xBytes)
        val y = BigInteger(1, yBytes)
        val point = ECPoint(x, y)

        val params = AlgorithmParameters.getInstance("EC")
        params.init(ECGenParameterSpec("secp256r1"))
        val ecParameters = params.getParameterSpec(ECParameterSpec::class.java)

        val kf = KeyFactory.getInstance("EC")
        val pubKeySpec = ECPublicKeySpec(point, ecParameters)
        return kf.generatePublic(pubKeySpec)
    }

    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val extractMac = Mac.getInstance("HmacSHA256")
        extractMac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = extractMac.doFinal(ikm)

        val expandMac = Mac.getInstance("HmacSHA256")
        expandMac.init(SecretKeySpec(prk, "HmacSHA256"))
        expandMac.update(info)
        expandMac.update(1.toByte())
        val okm = expandMac.doFinal()

        val result = ByteArray(length)
        System.arraycopy(okm, 0, result, 0, length)
        return result
    }

    private fun toFixed32(bi: BigInteger): ByteArray {
        val src = bi.toByteArray()
        val dest = ByteArray(32)
        if (src.size > 32) {
            System.arraycopy(src, src.size - 32, dest, 0, 32)
        } else {
            System.arraycopy(src, 0, dest, 32 - src.size, src.size)
        }
        return dest
    }
}
