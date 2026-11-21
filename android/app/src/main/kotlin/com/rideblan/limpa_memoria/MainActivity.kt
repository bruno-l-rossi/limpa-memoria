package com.rideblan.limpa_memoria

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
import com.google.android.gms.auth.api.identity.Identity
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
    // Rodada 19: autorização do Google pro motor nativo esperando a tela de
    // confirmação (quando o Google pede).
    private var autorizacaoPendente: MethodChannel.Result? = null
    private val reqAutorizacao = 7301

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
                    // Rodada 19 (A-15): a galeria inteira numa consulta só.
                    "galeria" -> {
                        ioPool.execute {
                            val r = try { consultarGaleria() } catch (_: Exception) { null }
                            main.post { result.success(r) }
                        }
                    }
                    // Rodada 19 (F4): motor nativo, que sobe com o app fechado.
                    "motorAutorizar" -> autorizar(call.argument<String>("email") ?: "", result)
                    "motorIniciar" -> result.success(MotorNativo.iniciar(
                        applicationContext,
                        call.argument<String>("email") ?: "",
                        call.argument<Boolean>("soWifi") ?: false,
                        (call.argument<Number>("bytes") ?: 0).toLong()))
                    "motorParar" -> {
                        MotorNativo.pararTudo(applicationContext)
                        result.success(true)
                    }
                    "motorRodando" -> result.success(MotorNativo.estaRodando())
                    "midias" -> {
                        ioPool.execute {
                            val r = consultarMidias()
                            main.post { result.success(r) }
                        }
                    }
                    "dirDados" -> result.success(applicationContext.filesDir.absolutePath)
                    "bateriaIsenta" -> result.success(bateriaIsenta())
                    "localizacaoMidia" -> result.success(localizacaoMidia())
                    // Rodada 18: a lixeira do sistema só existe no Android 11+.
                    "sdk" -> result.success(android.os.Build.VERSION.SDK_INT)
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

    /// Galeria inteira (rodada 19, A-15): os mesmos campos que o photo_manager
    /// lê, em arrays paralelos. Mesma regra de data do photo_manager (data da
    /// foto no Android 10+, senão a data em que entrou na galeria).
    private fun consultarGaleria(): HashMap<String, Any> {
        val q = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val col = mutableListOf("_id", "_size", "_data", "_display_name", "media_type",
            "date_added", "date_modified", "duration", "width", "height", "orientation",
            "mime_type")
        if (q) { col += "datetaken"; col += "relative_path" }
        val ids = ArrayList<Long>(); val sizes = ArrayList<Long>(); val paths = ArrayList<String>()
        val nomes = ArrayList<String>(); val tipos = ArrayList<Int>(); val datas = ArrayList<Long>()
        val mods = ArrayList<Long>(); val durs = ArrayList<Int>(); val largs = ArrayList<Int>()
        val alts = ArrayList<Int>(); val oris = ArrayList<Int>(); val rels = ArrayList<String>()
        val mimes = ArrayList<String>()
        contentResolver.query(
            MediaStore.Files.getContentUri("external"), col.toTypedArray(),
            "media_type IN (?, ?) AND bucket_id IS NOT NULL",
            arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
                MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()),
            "_id DESC"
        )?.use { c ->
            fun i(n: String) = c.getColumnIndex(n)
            val iId = i("_id"); val iSize = i("_size"); val iData = i("_data")
            val iNome = i("_display_name"); val iTipo = i("media_type")
            val iAdd = i("date_added"); val iMod = i("date_modified"); val iDur = i("duration")
            val iW = i("width"); val iH = i("height"); val iOri = i("orientation")
            val iMime = i("mime_type"); val iTaken = i("datetaken"); val iRel = i("relative_path")
            while (c.moveToNext()) {
                val tipoMs = c.getInt(iTipo)
                ids += c.getLong(iId)
                sizes += if (c.isNull(iSize)) 0L else c.getLong(iSize)
                paths += c.getString(iData) ?: ""
                nomes += c.getString(iNome) ?: ""
                tipos += if (tipoMs == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) 2 else 1
                var data = c.getLong(iAdd)
                if (q && iTaken >= 0 && !c.isNull(iTaken)) {
                    val t = c.getLong(iTaken) / 1000
                    if (t != 0L) data = t
                }
                datas += data
                mods += c.getLong(iMod)
                durs += if (tipoMs == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO && iDur >= 0)
                    (c.getLong(iDur) / 1000).toInt() else 0
                largs += if (iW >= 0) c.getInt(iW) else 0
                alts += if (iH >= 0) c.getInt(iH) else 0
                oris += if (iOri >= 0) c.getInt(iOri) else 0
                rels += if (iRel >= 0) (c.getString(iRel) ?: "") else ""
                mimes += if (iMime >= 0) (c.getString(iMime) ?: "") else ""
            }
        }
        return hashMapOf(
            "ids" to ids.toLongArray(), "sizes" to sizes.toLongArray(), "paths" to paths,
            "nomes" to nomes, "tipos" to tipos.toIntArray(), "datas" to datas.toLongArray(),
            "mods" to mods.toLongArray(), "durs" to durs.toIntArray(), "largs" to largs.toIntArray(),
            "alts" to alts.toIntArray(), "oris" to oris.toIntArray(), "rels" to rels,
            "mimes" to mimes, "q" to q,
        )
    }

    /// Autoriza o Drive pro motor nativo. Se o Google pedir confirmação, abre
    /// a tela dele (por isso só roda com o app aberto) e responde depois.
    private fun autorizar(email: String, result: MethodChannel.Result) {
        try {
            Identity.getAuthorizationClient(this).authorize(MotorNativo.pedido(email))
                .addOnSuccessListener { r ->
                    val pi = r.pendingIntent
                    if (r.hasResolution() && pi != null) {
                        autorizacaoPendente?.success(false)
                        autorizacaoPendente = result
                        try {
                            startIntentSenderForResult(pi.intentSender, reqAutorizacao, null, 0, 0, 0)
                        } catch (e: Exception) {
                            MotorNativo.registrar(this, "abrir autorização: $e")
                            autorizacaoPendente = null
                            result.success(false)
                        }
                    } else {
                        result.success(r.accessToken != null)
                    }
                }
                .addOnFailureListener { e ->
                    MotorNativo.registrar(this, "autorizar: $e")
                    result.success(false)
                }
        } catch (e: Exception) {
            MotorNativo.registrar(this, "autorizar: $e")
            result.success(false)
        }
    }

    @Deprecated("API de resultado antiga; a da autorização do Google ainda usa")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqAutorizacao) return
        val r = autorizacaoPendente ?: return
        autorizacaoPendente = null
        try {
            val res = Identity.getAuthorizationClient(this).getAuthorizationResultFromIntent(data)
            r.success(res.accessToken != null)
        } catch (e: Exception) {
            MotorNativo.registrar(this, "resultado da autorização: $e")
            r.success(false)
        }
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

    /// Permissão de ler o GPS do EXIF (Android 10+). Sem ela o arquivo lido
    /// vem com a localização apagada.
    private fun localizacaoMidia(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return try {
            checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        } catch (_: Exception) {
            true
        }
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
