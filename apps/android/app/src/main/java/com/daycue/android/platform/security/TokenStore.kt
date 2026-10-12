package com.daycue.android.platform.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 后端令牌的存放。
 *
 * 用 AndroidKeyStore 的 AES/GCM 加密后再进 SharedPreferences，而不是直接存明文：
 * app_setting 表与 SharedPreferences 都是可被备份、导出、误读的，令牌必须单独一层。
 *
 * 刻意不引入 androidx.security（EncryptedSharedPreferences）：它会给依赖树再加上
 * Tink 与它的传递依赖，而这里需要的只是「密钥不进应用进程内存以外的任何地方」，
 * 用系统 KeyStore 手写二十行即可，代价是可控的。
 */
class TokenStore(context: Context) {

    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** null 或空串等同撤销：宁可没有令牌，也不要留一个解不开的空密文。 */
    fun save(token: String?) {
        if (token.isNullOrEmpty()) {
            clear()
            return
        }
        try {
            val payload = encrypt(token)
            prefs.edit().putString(KEY_TOKEN, payload).apply()
        } catch (e: Exception) {
            // 密钥体系不可用（极少数定制 ROM 会禁用 KeyStore）时明确失败：
            // 写入失败也不能退回明文存储，那会让「加密」变成一句谎话。
            Log.e(TAG, "保存令牌失败，未写入任何内容", e)
        }
    }

    fun read(): String? {
        val stored = prefs.getString(KEY_TOKEN, null) ?: return null
        return try {
            decrypt(stored)
        } catch (e: Exception) {
            // 密钥被系统清除（重装、锁屏凭据失效）时旧密文永远解不开：
            // 清掉它并返回 null，让用户重新填一次，而不是把异常抛给界面。
            Log.w(TAG, "令牌解密失败，已清除本地密文", e)
            clear()
            null
        }
    }

    fun clear() {
        prefs.edit().remove(KEY_TOKEN).apply()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        // 加密时不指定 IV：让系统生成随机 IV，同一令牌每次密文都不同。
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ciphertext, Base64.NO_WRAP)
    }

    private fun decrypt(stored: String): String {
        val parts = stored.split(":")
        require(parts.size == 2) { "密文格式不正确" }
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    /** 首次使用时生成密钥；已存在就直接取用。GCM 的认证标签能同时发现篡改。 */
    private fun secretKey(): SecretKey = synchronized(KEY_LOCK) {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getEntry(KEY_ALIAS, null)
        if (existing is KeyStore.SecretKeyEntry) return@synchronized existing.secretKey

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                // GCM 不需要填充，指定别的填充在 KeyStore 里会直接抛异常。
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        generator.generateKey()
    }

    private companion object {
        const val TAG = "TokenStore"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "daycue.backend.token"
        const val PREFS_NAME = "daycue_secure"
        const val KEY_TOKEN = "backend.token"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_TAG_BITS = 128

        /** KeyStore 的生成不是线程安全的：两个线程同时初始化会有一个直接失败。 */
        val KEY_LOCK = Any()
    }
}
