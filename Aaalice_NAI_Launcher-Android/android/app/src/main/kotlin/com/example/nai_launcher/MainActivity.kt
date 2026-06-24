package com.example.nai_launcher // 👈 改成这个！
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.nai.launcher/share"
    private var methodChannel: MethodChannel? = null
    private val pendingShareData = mutableListOf<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getPendingShareData") {
                result.success(pendingShareData.toList())
                pendingShareData.clear()
            } else {
                result.notImplemented()
            }
        }
    }

    // App 冷启动时接收分享
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    // App 在后台运行时接收分享
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        val action = intent.action
        val type = intent.type
        val sharedItems = mutableListOf<String>()

        if (Intent.ACTION_SEND == action && type != null) {
            // 1. 优先尝试提取文本/网址 (很多App分享的类型很乱，直接抓 EXTRA_TEXT 最准)
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                // 只要包含 http 就按 url 处理，方便 Dart 端正则提取
                if (text.contains("http://") || text.contains("https://")) {
                    sharedItems.add("url:$text")
                } else {
                    sharedItems.add("text:$text")
                }
            }

            // 2. 尝试提取文件/图片流 (有些分享会同时带文本和文件)
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (uri != null) {
                copyUriToCache(this, uri)?.let { path ->
                    // 如果已经抓到了文本，就不再重复发送文件，防止 Flutter 弹窗冲突
                    if (sharedItems.isEmpty()) {
                        sharedItems.add("file:$path")
                    }
                }
            }
        } else if (Intent.ACTION_SEND_MULTIPLE == action && type != null) {
            // 3. 处理多文件/多图
            val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            uris?.forEach { uri ->
                copyUriToCache(this, uri)?.let { path ->
                    sharedItems.add("file:$path")
                }
            }
        }

        // 4. 发送给 Flutter
        if (sharedItems.isNotEmpty()) {
            if (methodChannel != null) {
                methodChannel?.invokeMethod("onSharedData", sharedItems)
            } else {
                pendingShareData.addAll(sharedItems)
            }
        }
    }
    
    // 核心逻辑：将受保护的 content:// 复制到应用缓存目录，转为物理路径
    private fun copyUriToCache(context: Context, uri: Uri): String? {
        return try {
            var fileName = "shared_${System.currentTimeMillis()}"
            
            // 尝试获取原文件名
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex != -1) {
                        fileName = cursor.getString(nameIndex)
                    }
                }
            }

            // 如果名字没有后缀，根据 MimeType 补全后缀
            if (!fileName.contains(".")) {
                val mimeType = context.contentResolver.getType(uri)
                val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
                if (ext != null) {
                    fileName += ".$ext"
                }
            }

            // 写入 Cache 目录
            val tempFile = File(context.cacheDir, "share_${System.currentTimeMillis()}_$fileName")
            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(tempFile).use { output ->
                    input.copyTo(output)
                }
            }
            tempFile.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
}