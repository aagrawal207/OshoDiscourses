package com.agraabhi.oshodiscourses.billing

import com.google.common.truth.Truth.assertThat
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.Base64
import org.junit.Test

class PlaySignatureVerifierTest {
    private val keys = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
    private val licenseKey = Base64.getEncoder().encodeToString(keys.public.encoded)
    private val json = """{"orderId":"GPA.1","productId":"com.agraabhi.oshodiscourses.tip.small","purchaseState":0}"""

    private fun sign(text: String): String = Signature.getInstance("SHA1withRSA").run {
        initSign(keys.private)
        update(text.toByteArray())
        Base64.getEncoder().encodeToString(sign())
    }

    private fun purchase(json: String, signature: String) =
        StorePurchase("GPA.1", "token", listOf("com.agraabhi.oshodiscourses.tip.small"), PurchaseStatus.PURCHASED, originalJson = json, signature = signature)

    @Test
    fun acceptsOnlyPlaySignedPurchaseJson() {
        val verifier = PurchaseVerifier.forLicenseKey(licenseKey)
        assertThat(verifier.verify(purchase(json, sign(json)))).isTrue()
        assertThat(verifier.verify(purchase(json.replace("GPA.1", "GPA.2"), sign(json)))).isFalse()
        assertThat(verifier.verify(purchase(json, ""))).isFalse()
        assertThat(verifier.verify(purchase(json, "not base64!"))).isFalse()
    }

    @Test
    fun malformedKeyFailsClosedAndMissingKeyIsUnchecked() {
        assertThat(PlaySignatureVerifier("not-a-key").verify(purchase(json, sign(json)))).isFalse()
        assertThat(PurchaseVerifier.forLicenseKey(null)).isSameInstanceAs(PurchaseVerifier.UNCHECKED)
        assertThat(PurchaseVerifier.forLicenseKey(" ")).isSameInstanceAs(PurchaseVerifier.UNCHECKED)
    }
}
