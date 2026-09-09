package dev.qiyu.app

import android.content.Context
import android.content.pm.PackageManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_STORE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            handleSecureStoreCall(call, result, applicationContext)
        }
        // 语音链路（票 06）：录音（AudioRecord，含麦克风权限系统弹窗）
        // 与朗读（MediaPlayer 内存播放）两条原生通道，实现见 VoiceBridge。
        VoiceBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    override fun onDestroy() {
        // 隐私收尾：界面销毁后麦克风不该还亮着。趁引擎尚在先请 VoiceBridge
        // 收尾（等待中的权限回包还能送出），再交给父类拆引擎。
        VoiceBridge.unregister()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC_PERMISSION_REQUEST_CODE) {
            VoiceBridge.onRequestPermissionsResult(
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED,
            )
        }
    }

    private fun handleSecureStoreCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context,
    ) {
        try {
            when (call.method) {
                "get" -> {
                    val scope = call.scope() ?: return badArguments(result)
                    result.success(SecureStore.get(context, scope))
                }
                "set" -> {
                    val scope = call.scope() ?: return badArguments(result)
                    val value = call.value() ?: return badArguments(result)
                    SecureStore.set(context, scope, value)
                    result.success(null)
                }
                "delete" -> {
                    val scope = call.scope() ?: return badArguments(result)
                    SecureStore.delete(context, scope)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            // 隐私红线：对外错误只给固定文案，绝不携带 scope 或 Key 内容。
            result.error("SECURE_STORE_ERROR", "本机安全存储暂不可用。", null)
        }
    }

    private fun badArguments(result: MethodChannel.Result) {
        result.error("BAD_ARGUMENT", "本机安全存储的请求参数不完整。", null)
    }

    private fun MethodCall.scope(): String? =
        (arguments as? Map<*, *>)?.get("scope") as? String

    private fun MethodCall.value(): String? =
        (arguments as? Map<*, *>)?.get("value") as? String
}

private const val SECURE_STORE_CHANNEL = "dev.qiyu.app/secure_store"

/**
 * AndroidKeyStore 支撑的安全存储：AES-256/GCM 密钥入 AndroidKeyStore
 * （不可导出），密文条目按 SecretStore 的 scope 一一对应，密文与独立
 * 随机 IV 一起 Base64 后落应用私有 SharedPreferences——单独拿到存储
 * 文件解不出任何条目。
 *
 * 删除幂等：条目不存在同样是成功，与 Windows 凭据管理器实现对
 * ERROR_NOT_FOUND 的语义对齐（Host 每次保存配置都会清理凭据仓，
 * 不幂等会把保存打穿成 500）。
 */
private object SecureStore {
    private const val KEY_ALIAS = "qiyu_provider_api_key"
    private const val PREFS_NAME = "qiyu_secure_store"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val GCM_IV_BYTES = 12
    private const val GCM_TAG_BITS = 128
    private const val ENTRY_PREFIX = "qiyu.secure."

    /** 密钥 check-then-generate 的锁：MethodChannel 处理器当前在主线程
     * 串行执行，锁不依赖这个前提，多线程调用同样安全。 */
    private val keyLock = Any()

    fun get(context: Context, scope: String): String? {
        val stored = prefs(context).getString(entryKey(scope), null) ?: return null
        val blob = Base64.decode(stored, Base64.NO_WRAP)
        val iv = blob.copyOfRange(0, GCM_IV_BYTES)
        val ciphertext = blob.copyOfRange(GCM_IV_BYTES, blob.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateKey(),
            GCMParameterSpec(GCM_TAG_BITS, iv),
        )
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    fun set(context: Context, scope: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val blob = Base64.encodeToString(cipher.iv + ciphertext, Base64.NO_WRAP)
        prefs(context).edit().putString(entryKey(scope), blob).apply()
    }

    fun delete(context: Context, scope: String) {
        prefs(context).edit().remove(entryKey(scope)).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun entryKey(scope: String): String {
        // 与 Windows 凭据管理器实现同构：scope 先 sha256 再入存储键名，
        // Provider 语义（URL 等）不以明文出现在存储文件里；Dart 侧通道
        // 协议不变，哈希只发生在原生存储这一层。
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(scope.toByteArray(Charsets.UTF_8))
        val hex = digest.joinToString(separator = "") { "%02x".format(it) }
        return "$ENTRY_PREFIX$hex"
    }

    private fun getOrCreateKey(): SecretKey = synchronized(keyLock) {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE)
        keyStore.load(null)
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { entry ->
            return entry.secretKey
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }
}
