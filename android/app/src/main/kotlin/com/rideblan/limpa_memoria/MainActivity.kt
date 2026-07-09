package com.rideblan.limpa_memoria

import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Canal nativo do app. Três serviços que o Flutter não alcança direito:
///
/// 1. "midias": tamanho (SIZE) e caminho real (DATA) de TODAS as mídias numa
///    consulta só ao MediaStore. Substitui abrir arquivo por arquivo via
///    photo_manager, que chegava a COPIAR o vídeo pro cache só pra ler o
///    tamanho. Numa galeria de 19 mil arquivos, é a diferença entre minutos
///    e menos de 1 segundo.
/// 2. "bateriaIsenta"/"pedirIsencaoBateria": isenção de otimização de bateria,
///    pra um backup de horas não ser morto pelo Doze de madrugada.
/// 3. "dirDados": pasta de dados do app pro armazenamento em arquivo do
///    upload_store (sem depender de plugin novo).
class MainActivity : FlutterActivity() {
    private val canal = "limpa_memoria/nativo"

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
