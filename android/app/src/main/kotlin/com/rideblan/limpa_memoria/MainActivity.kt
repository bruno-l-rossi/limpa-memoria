package com.rideblan.limpa_memoria

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/// Canal nativo do app. Serviços que o Flutter não alcança direito, sem
/// depender de plugin novo:
///
/// - "midias": tamanho (SIZE) e caminho real (DATA) de TODAS as mídias numa
///   consulta só ao MediaStore (substitui abrir arquivo por arquivo).
/// - "bateriaIsenta"/"pedirIsencaoBateria": isenção do Doze pra job de horas.
/// - "dirDados": pasta de dados do app pro armazenamento em arquivo.
/// - "md5": hash MD5 de um arquivo, em thread própria (integridade do upload).
/// - "compartilhar": share sheet do Android com um texto.
/// - "notificar"/"limparNotificacao": notificação de progresso com o número
///   REAL da sessão ("4.312 de 19.000"), que o background_downloader não sabe.
class MainActivity : FlutterActivity() {
    private val canal = "limpa_memoria/nativo"
    private val canalNotif = "backup_progresso"
    private val idNotif = 4242

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, canal)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "midias" -> result.success(consultarMidias())
                    "dirDados" -> result.success(applicationContext.filesDir.absolutePath)
                    "bateriaIsenta" -> result.success(bateriaIsenta())
                    "pedirIsencaoBateria" -> {
                        pedirIsencaoBateria()
                        result.success(bateriaIsenta())
                    }
                    "md5" -> md5Async(call.argument<String>("path"), result)
                    "compartilhar" -> {
                        compartilhar(call.argument<String>("texto") ?: "")
                        result.success(true)
                    }
                    "notificar" -> {
                        notificar(
                            call.argument<String>("titulo") ?: "Limpa Memória",
                            call.argument<String>("texto") ?: "",
                            call.argument<Int>("feitos") ?: 0,
                            call.argument<Int>("total") ?: 0,
                        )
                        result.success(true)
                    }
                    "limparNotificacao" -> {
                        limparNotificacao()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Mapa id -> [tamanho em bytes, caminho real]. Uma consulta só, indexada.
    /// O id do MediaStore é o mesmo que o photo_manager usa como AssetEntity.id.
    private fun consultarMidias(): HashMap<String, ArrayList<Any>> {
        val mapa = HashMap<String, ArrayList<Any>>()
        val projecao = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATA,
        )
        val selecao = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
        )
        try {
            contentResolver.query(
                MediaStore.Files.getContentUri("external"),
                projecao, selecao, args, null
            )?.use { c ->
                val iId = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val iSize = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                val iData = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATA)
                while (c.moveToNext()) {
                    val id = c.getLong(iId).toString()
                    val tamanho = c.getLong(iSize)
                    val caminho = c.getString(iData) ?: ""
                    mapa[id] = arrayListOf(tamanho, caminho)
                }
            }
        } catch (_: Exception) {
            // Devolve o que conseguiu; o Dart tem fallback por arquivo.
        }
        return mapa
    }

    /// MD5 de um arquivo em thread própria (não trava a UI nem o canal).
    /// Devolve o hash em hex minúsculo, ou null se não deu.
    private fun md5Async(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.success(null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        Thread {
            var hex: String? = null
            try {
                val md = MessageDigest.getInstance("MD5")
                FileInputStream(File(path)).use { fis ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = fis.read(buf)
                        if (n <= 0) break
                        md.update(buf, 0, n)
                    }
                }
                hex = md.digest().joinToString("") { "%02x".format(it) }
            } catch (_: Exception) {}
            main.post { result.success(hex) }
        }.start()
    }

    private fun compartilhar(texto: String) {
        try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, texto)
            }
            startActivity(Intent.createChooser(intent, "Compartilhar"))
        } catch (_: Exception) {}
    }

    /// Notificação com o número real da sessão e barra de progresso. Convive
    /// com a notificação do foreground service (que é estática de propósito).
    private fun notificar(titulo: String, texto: String, feitos: Int, total: Int) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        canalNotif, "Progresso do backup",
                        NotificationManager.IMPORTANCE_LOW // sem som a cada update
                    )
                )
            }
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(this, canalNotif)
            else
                @Suppress("DEPRECATION") Notification.Builder(this)
            b.setContentTitle(titulo)
                .setContentText(texto)
                .setSmallIcon(applicationInfo.icon)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
            if (total > 0) b.setProgress(total, feitos.coerceAtMost(total), false)
            nm.notify(idNotif, b.build())
        } catch (_: Exception) {}
    }

    private fun limparNotificacao() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(idNotif)
        } catch (_: Exception) {}
    }

    private fun bateriaIsenta(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun pedirIsencaoBateria() {
        if (bateriaIsenta()) return
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (_: Exception) {
            // Alguns aparelhos bloqueiam o pedido direto; abre a lista geral.
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {}
        }
    }
}
