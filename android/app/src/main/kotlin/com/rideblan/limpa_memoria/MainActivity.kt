package com.rideblan.limpa_memoria

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
import java.util.concurrent.Executors

/// Canal nativo do app. Serviços que o Flutter não alcança direito, sem
/// depender de plugin novo:
///
/// - "midias": tamanho (SIZE) e caminho real (DATA) de TODAS as mídias numa
///   consulta só ao MediaStore (substitui abrir arquivo por arquivo).
///   Rodada 10: roda FORA da thread principal (com 30 mil mídias a consulta
///   levava segundos e travava a tela, risco de ANR) e devolve arrays
///   tipados, que atravessam o canal muito mais rápido que um mapa.
/// - "bateriaIsenta"/"pedirIsencaoBateria": isenção do Doze pra job de horas.
/// - "dirDados": pasta de dados do app pro armazenamento em arquivo.
/// - "md5": hash MD5 de um arquivo, num pool de 2 threads (integridade do
///   upload sem abrir uma thread nova por arquivo).
/// - "compartilhar": share sheet do Android com um texto.
/// - "notificar"/"limparNotificacao": notificação de progresso com o número
///   REAL da sessão ("4.312 de 19.000"), que o background_downloader não sabe.
class MainActivity : FlutterActivity() {
    private val canal = "limpa_memoria/nativo"
    private val canalNotif = "backup_progresso"
    private val idNotif = 4242
    private val main = Handler(Looper.getMainLooper())

    companion object {
        // Consulta ao MediaStore: 1 thread basta (é uma consulta por vez).
        private val ioPool = Executors.newSingleThreadExecutor()
        // MD5: 2 threads. Mais que isso disputa disco com o próprio upload.
        private val md5Pool = Executors.newFixedThreadPool(2)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, canal)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "midias" -> {
                        ioPool.execute {
                            val r = consultarMidias()
                            main.post { result.success(r) }
                        }
                    }
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

    /// {"ids": LongArray, "sizes": LongArray, "paths": List<String>}, mesma
    /// ordem nos 3. Uma consulta só, indexada. O id do MediaStore é o mesmo que
    /// o photo_manager usa como AssetEntity.id.
    private fun consultarMidias(): HashMap<String, Any> {
        val ids = ArrayList<Long>()
        val sizes = ArrayList<Long>()
        val paths = ArrayList<String>()
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
                ids.ensureCapacity(c.count)
                sizes.ensureCapacity(c.count)
                paths.ensureCapacity(c.count)
                while (c.moveToNext()) {
                    ids.add(c.getLong(iId))
                    sizes.add(if (c.isNull(iSize)) 0L else c.getLong(iSize))
                    paths.add(c.getString(iData) ?: "")
                }
            }
        } catch (_: Exception) {
            // Devolve o que conseguiu; o Dart tem fallback por arquivo.
        }
        return hashMapOf(
            "ids" to ids.toLongArray(),
            "sizes" to sizes.toLongArray(),
            "paths" to paths,
        )
    }

    /// MD5 de um arquivo fora da thread principal.
    /// Devolve o hash em hex minúsculo, ou null se não deu.
    private fun md5Async(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.success(null)
            return
        }
        md5Pool.execute {
            var hex: String? = null
            try {
                val md = MessageDigest.getInstance("MD5")
                FileInputStream(File(path)).use { fis ->
                    val buf = ByteArray(1 shl 17)
                    while (true) {
                        val n = fis.read(buf)
                        if (n <= 0) break
                        md.update(buf, 0, n)
                    }
                }
                val sb = StringBuilder(32)
                for (b in md.digest()) {
                    val v = b.toInt() and 0xff
                    if (v < 16) sb.append('0')
                    sb.append(Integer.toHexString(v))
                }
                hex = sb.toString()
            } catch (_: Exception) {}
            main.post { result.success(hex) }
        }
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
    /// Tocar nela abre o app (antes não fazia nada).
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
            try {
                val abrir = packageManager.getLaunchIntentForPackage(packageName)
                if (abrir != null) {
                    abrir.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                    b.setContentIntent(PendingIntent.getActivity(this, 0, abrir, flags))
                }
            } catch (_: Exception) {}
            if (total > 0) b.setProgress(total, feitos.coerceAtMost(total), false)
            // O app renova esta notificação a cada ~15s enquanto vive. Se o
            // processo morrer, ela some em 2 min em vez de mostrar um número
            // congelado ("subindo") que não anda mais.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) b.setTimeoutAfter(120_000L)
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
        return try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (_: Exception) {
            false
        }
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
