package com.rideblan.limpa_memoria

import android.accounts.Account
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.webkit.MimeTypeMap
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Tasks
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/// Motor nativo do backup (rodada 19, fase F4). Sobe com o app fechado.
///
/// Roda como trabalho iniciado pelo usuário (UIDT, Android 14+), sem o teto de
/// 6 h do serviço dataSync; abaixo do 14 roda como serviço em primeiro plano.
/// Conversa com o Dart só por arquivos em filesDir/motor/ (1 escritor por
/// arquivo):
///   fila.json         Dart escreve: o que subir (id, nome, caminho, pasta...)
///   resultados.jsonl  motor escreve: 1 linha por arquivo concluído ou falho
///   sessoes.json      motor escreve: URL da sessão retomável de cada arquivo
///   estado.json       motor escreve: progresso, a cada ~2 s
///   config.json       Dart escreve (via iniciar): conta e "só no wifi"
/// O token vem da API de autorização do Google (sem tela): o app só precisa
/// estar aberto na primeira vez, pra pessoa autorizar.
object MotorNativo {
    const val ID_JOB = 4600
    const val ID_NOTIF = 4343
    const val ID_NOTIF_FIM = 4344
    const val CANAL = "motor_backup"
    const val ESCOPO = "https://www.googleapis.com/auth/drive.file"
    private const val TRABALHADORES = 3
    private const val TETO_MD5 = 4L * 1024 * 1024 * 1024 // A-08: 4 GB
    private const val TENTATIVAS_REDE = 12

    private val rodando = AtomicBoolean(false)
    @Volatile private var parar = false
    @Volatile var paradoPeloUsuario = false

    fun dir(ctx: Context): File = File(ctx.filesDir, "motor").apply { mkdirs() }

    fun estaRodando(): Boolean = rodando.get()

    // -------------------------------------------------------------------------
    // Controle (chamado pela MainActivity, com o app na tela)
    // -------------------------------------------------------------------------

    /// Liga o motor. Com o app visível (exigência do UIDT). Devolve true se
    /// agendou ou já estava rodando.
    fun iniciar(ctx: Context, email: String, soWifi: Boolean, bytes: Long): Boolean {
        val d = dir(ctx)
        escreverAtomico(File(d, "config.json"),
            JSONObject().put("email", email).put("soWifi", soWifi).toString())
        paradoPeloUsuario = false
        parar = false
        if (rodando.get()) return true // o trabalho em curso relê a fila
        return try {
            if (Build.VERSION.SDK_INT >= 34) {
                val js = ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
                val info = JobInfo.Builder(ID_JOB, ComponentName(ctx, MotorJobService::class.java))
                    .setUserInitiated(true)
                    .setRequiredNetworkType(
                        if (soWifi) JobInfo.NETWORK_TYPE_UNMETERED else JobInfo.NETWORK_TYPE_ANY)
                    .setEstimatedNetworkBytes(bytes.coerceAtLeast(1), 0)
                    .build()
                if (js.schedule(info) == JobScheduler.RESULT_SUCCESS) true
                else iniciarServico(ctx)
            } else iniciarServico(ctx)
        } catch (e: Exception) {
            registrar(ctx, "iniciar UIDT falhou: $e")
            iniciarServico(ctx)
        }
    }

    private fun iniciarServico(ctx: Context): Boolean = try {
        val i = Intent(ctx, MotorService::class.java)
        if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        true
    } catch (e: Exception) {
        registrar(ctx, "iniciar serviço falhou: $e")
        false
    }

    /// Para tudo (Parar no app). O que já subiu fica; as sessões ficam salvas
    /// pra o arquivo grande continuar de onde estava quando retomar.
    fun pararTudo(ctx: Context) {
        paradoPeloUsuario = true
        parar = true
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                (ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).cancel(ID_JOB)
            }
        } catch (_: Exception) {}
        try { ctx.stopService(Intent(ctx, MotorService::class.java)) } catch (_: Exception) {}
    }

    /// O sistema pediu pra parar (rede caiu, bateria): volta sozinho depois.
    fun interromper() { parar = true }

    // -------------------------------------------------------------------------
    // Trabalho
    // -------------------------------------------------------------------------

    data class Item(
        val id: String, val titulo: String, val path: String, val bytes: Long,
        val data: Long, val paiId: String,
    )

    private class Sessao(val url: String, val total: Long)

    private class Estado {
        val total = AtomicInteger(0)
        val feitos = AtomicInteger(0)
        val falhas = AtomicInteger(0)
        val bytesTotal = AtomicLong(0)
        val bytesFeitos = AtomicLong(0)
        @Volatile var semRede = false
        @Volatile var precisaLogin = false
        @Volatile var driveCheio = false
        @Volatile var ultimoErro: String? = null
        // amostras (tempo, bytes acumulados) pra velocidade dos últimos 2 min
        val amostras = ArrayDeque<Pair<Long, Long>>()
    }

    /// Roda até a fila acabar ou alguém mandar parar. Chama aoTerminar(reagendar)
    /// no fim, numa thread própria.
    fun rodar(ctx: Context, aoNotificar: (Notification) -> Unit, aoTerminar: (Boolean) -> Unit) {
        if (!rodando.compareAndSet(false, true)) {
            aoTerminar(false)
            return
        }
        parar = false
        Thread({
            var reagendar = false
            try {
                reagendar = trabalhar(ctx.applicationContext, aoNotificar)
            } catch (e: Throwable) {
                registrar(ctx, "motor caiu: $e")
                reagendar = !paradoPeloUsuario
            } finally {
                rodando.set(false)
                aoTerminar(reagendar)
            }
        }, "motor-backup").start()
    }

    /// true = parou no meio por motivo do sistema (o UIDT reagenda).
    private fun trabalhar(ctx: Context, aoNotificar: (Notification) -> Unit): Boolean {
        val d = dir(ctx)
        val cfg = lerJson(File(d, "config.json")) ?: return false
        val email = cfg.optString("email")
        val soWifi = cfg.optBoolean("soWifi", false)
        if (email.isEmpty()) return false
        val token = Token(ctx, email)
        val est = Estado()
        val feitos = lerConcluidos(d)
        val sessoes = lerSessoes(d)
        val emCurso = ConcurrentHashMap.newKeySet<String>()
        // Falhou nesta rodada: não pega de novo (quem decide re-tentar é o app).
        val falhosRodada = ConcurrentHashMap.newKeySet<String>()
        val vistos = ConcurrentHashMap.newKeySet<String>() // 3 threads mexem
        val fila = LinkedBlockingDeque<Item>()
        var filaMod = -1L

        fun recarregarFila() {
            val f = File(d, "fila.json")
            val mod = f.lastModified()
            if (mod == filaMod) return
            filaMod = mod
            val itens = lerFila(f)
            val ids = itens.map { it.id }.toHashSet()
            // Saiu da fila (Parar, troca de sessão): esquece.
            fila.removeIf { it.id !in ids }
            var total = 0
            var bt = 0L
            var feitosN = 0
            var bf = 0L
            for (it in itens) {
                total++
                bt += it.bytes
                if (it.id in feitos) {
                    feitosN++
                    bf += it.bytes
                    continue
                }
                if (it.id !in vistos && it.id !in emCurso && it.id !in falhosRodada) {
                    vistos.add(it.id)
                    fila.add(it)
                }
            }
            est.total.set(total)
            est.bytesTotal.set(bt)
            est.feitos.set(feitosN)
            est.bytesFeitos.set(bf)
        }

        recarregarFila()
        canal(ctx)
        aoNotificar(notificacao(ctx, est, true))
        val pool = Executors.newFixedThreadPool(TRABALHADORES)
        val ativos = AtomicInteger(0)
        var ultimaNotif = 0L
        var vaziaDesde = 0L
        try {
            while (!parar) {
                recarregarFila()
                if (est.precisaLogin || est.driveCheio) break
                if (!temRede(ctx, soWifi)) {
                    est.semRede = true
                } else {
                    est.semRede = false
                    while (ativos.get() < TRABALHADORES && fila.isNotEmpty() && !parar) {
                        val item = fila.poll() ?: break
                        emCurso.add(item.id)
                        ativos.incrementAndGet()
                        pool.execute {
                            try {
                                subirItem(ctx, item, token, est, sessoes, feitos, soWifi)
                                if (item.id !in feitos) falhosRodada.add(item.id)
                            } catch (e: Throwable) {
                                falhosRodada.add(item.id)
                                registrar(ctx, "item ${item.id}: $e")
                            } finally {
                                emCurso.remove(item.id)
                                vistos.remove(item.id) // se não concluiu, pode voltar
                                ativos.decrementAndGet()
                            }
                        }
                    }
                }
                val agora = System.currentTimeMillis()
                if (agora - ultimaNotif > 2000) {
                    ultimaNotif = agora
                    aoNotificar(notificacao(ctx, est, true))
                    gravarEstado(d, est, true)
                }
                if (fila.isEmpty() && ativos.get() == 0) {
                    if (vaziaDesde == 0L) vaziaDesde = agora
                    // 10 s sem nada novo na fila: acabou.
                    if (agora - vaziaDesde > 10_000) break
                } else vaziaDesde = 0L
                Thread.sleep(500)
            }
        } catch (_: InterruptedException) {
        }
        // Por que parou: sistema (rede/bateria, volta sozinho), pessoa, login
        // ou Drive cheio. Decide antes de mexer no "parar".
        val peloSistema = parar && !paradoPeloUsuario && !est.precisaLogin && !est.driveCheio
        val acabou = !parar && !est.precisaLogin && !est.driveCheio
        // Corta o que ainda está subindo (login/Drive cheio também param tudo)
        // e espera as threads saírem: nunca 2 rodadas subindo o mesmo arquivo.
        parar = true
        desconectarTodos()
        pool.shutdown()
        try { pool.awaitTermination(60, TimeUnit.SECONDS) } catch (_: Exception) {}
        gravarEstado(d, est, false)
        notificarFim(ctx, est, acabou)
        return peloSistema
    }

    // Conexões abertas, pra cortar na hora do Parar.
    private val conexoes = ConcurrentHashMap.newKeySet<HttpURLConnection>()
    private fun desconectarTodos() {
        for (c in conexoes) try { c.disconnect() } catch (_: Exception) {}
        conexoes.clear()
    }

    private fun subirItem(
        ctx: Context, item: Item, token: Token, est: Estado,
        sessoes: MutableMap<String, Sessao>, feitos: MutableSet<String>, soWifi: Boolean,
    ) {
        val d = dir(ctx)
        val arq = File(item.path)
        if (item.path.isEmpty() || !arq.exists()) {
            resultadoFalha(d, item, "arquivo não está mais no celular", true, est)
            return
        }
        val total = arq.length()
        var tentativasRede = 0
        var tentativasToken = 0
        var md5Refeito = false
        while (!parar) {
            try {
                var s = sessoes[item.id]
                if (s != null && s.total != total) s = null // arquivo mudou
                var offset = 0L
                var resposta: JSONObject? = null
                if (s != null) {
                    val (cod, corpo, range) = consultar(s.url, total)
                    when (cod) {
                        200, 201 -> resposta = JSONObject(corpo ?: "{}")
                        308 -> offset = MotorUtil.recebidos(range)
                        else -> {
                            if (MotorUtil.classificar(cod, corpo, true) == MotorUtil.Erro.SESSAO_EXPIROU) {
                                s = null
                            } else throw HttpErro(cod, corpo, true)
                        }
                    }
                }
                if (s == null && resposta == null) {
                    s = criarSessao(item, total, token)
                    sessoes[item.id] = s
                    salvarSessoes(d, sessoes)
                    offset = 0
                }
                // MD5 junto com a leitura quando vai mandar do zero (1 leitura
                // só). Se o Drive já tinha tudo (resposta pronta), o MD5 vem do
                // arquivo, nunca de um digest vazio.
                val md = if (resposta == null && offset == 0L && total <= TETO_MD5)
                    MessageDigest.getInstance("MD5") else null
                if (resposta == null) {
                    resposta = mandarBlocos(s!!, arq, offset, total, md, est)
                }
                if (resposta == null) continue // 308 inesperado no fim: consulta de novo
                val fileId = resposta.optString("id")
                // Sem id não dá pra provar que subiu: trata como falha de rede
                // (consulta a sessão de novo na próxima volta).
                if (fileId.isEmpty()) throw IOException("Drive respondeu sem id")
                val md5Drive = resposta.optString("md5Checksum").ifEmpty { null }
                var md5Local: String? = null
                if (md5Drive != null && total <= TETO_MD5) {
                    md5Local = if (md != null) hex(md.digest()) else md5Arquivo(arq)
                }
                if (md5Local != null && md5Drive != null && md5Local != md5Drive) {
                    // Chegou diferente: apaga no Drive e sobe de novo (1 vez).
                    try { apagarNoDrive(fileId, token) } catch (_: Exception) {}
                    sessoes.remove(item.id)
                    salvarSessoes(d, sessoes)
                    if (md5Refeito) {
                        resultadoFalha(d, item, "conteúdo chegou diferente no Drive", true, est)
                        return
                    }
                    md5Refeito = true
                    continue
                }
                resultadoOk(d, item, fileId, total, md5Local != null && md5Local == md5Drive, est)
                feitos.add(item.id)
                sessoes.remove(item.id)
                salvarSessoes(d, sessoes)
                return
            } catch (e: HttpErro) {
                when (MotorUtil.classificar(e.codigo, e.corpo, e.naSessao)) {
                    MotorUtil.Erro.TOKEN -> {
                        token.invalidar()
                        if (++tentativasToken > 3) {
                            est.precisaLogin = true
                            return
                        }
                    }
                    MotorUtil.Erro.DRIVE_CHEIO -> {
                        est.driveCheio = true
                        resultadoFalha(d, item, "drive_cheio", false, est)
                        return
                    }
                    MotorUtil.Erro.TAXA -> {
                        if (++tentativasRede > TENTATIVAS_REDE) {
                            resultadoFalha(d, item, "Drive ocupado (HTTP ${e.codigo})", false, est)
                            return
                        }
                        dormir(MotorUtil.esperaMs(tentativasRede))
                    }
                    MotorUtil.Erro.SESSAO_EXPIROU -> {
                        sessoes.remove(item.id)
                        salvarSessoes(d, sessoes)
                    }
                    else -> {
                        resultadoFalha(d, item, "HTTP ${e.codigo}: ${e.corpo?.take(200)}", true, est)
                        return
                    }
                }
            } catch (e: PrecisaLogin) {
                est.precisaLogin = true
                return
            } catch (e: IOException) {
                if (parar) return
                // Sem rede: espera voltar sem gastar tentativa.
                if (!temRede(ctx, soWifi)) {
                    est.semRede = true
                    while (!parar && !temRede(ctx, soWifi)) dormir(10_000)
                    continue
                }
                est.ultimoErro = e.toString()
                if (++tentativasRede > TENTATIVAS_REDE) {
                    resultadoFalha(d, item, "rede: $e", false, est)
                    return
                }
                dormir(MotorUtil.esperaMs(tentativasRede))
            }
        }
    }

    private class HttpErro(val codigo: Int, val corpo: String?, val naSessao: Boolean) :
        Exception("HTTP $codigo")

    private class PrecisaLogin : Exception("precisa autorizar de novo")

    private fun abrir(url: String): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 30_000
        c.readTimeout = 120_000
        c.instanceFollowRedirects = false // o 308 do Drive não é redirecionamento
        conexoes.add(c)
        return c
    }

    private fun ler(c: HttpURLConnection): Pair<Int, String?> {
        val cod = c.responseCode
        val s = if (cod in 200..399) c.inputStream else c.errorStream
        val corpo = try { s?.bufferedReader()?.use { it.readText() } } catch (_: Exception) { null }
        return cod to corpo
    }

    private fun criarSessao(item: Item, total: Long, token: Token): Sessao {
        val c = abrir("https://www.googleapis.com/upload/drive/v3/files" +
            "?uploadType=resumable&fields=id,size,md5Checksum&supportsAllDrives=false")
        try {
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Authorization", "Bearer ${token.valor()}")
            c.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
            c.setRequestProperty("X-Upload-Content-Type", mime(item.titulo))
            c.setRequestProperty("X-Upload-Content-Length", total.toString())
            val corpo = MotorUtil.metadado(item.titulo, item.paiId, item.data).toByteArray()
            c.setFixedLengthStreamingMode(corpo.size)
            c.outputStream.use { it.write(corpo) }
            val (cod, resp) = ler(c)
            if (cod != 200) throw HttpErro(cod, resp, false)
            val url = c.getHeaderField("Location") ?: throw IOException("sessão sem Location")
            return Sessao(url, total)
        } finally {
            conexoes.remove(c)
            c.disconnect()
        }
    }

    /// Pergunta ao Drive quanto chegou: (código, corpo, Range).
    private fun consultar(url: String, total: Long): Triple<Int, String?, String?> {
        val c = abrir(url)
        try {
            c.requestMethod = "PUT"
            c.doOutput = true
            c.setRequestProperty("Content-Range", MotorUtil.contentRangeConsulta(total))
            c.setFixedLengthStreamingMode(0)
            c.outputStream.close()
            val (cod, corpo) = ler(c)
            return Triple(cod, corpo, c.getHeaderField("Range"))
        } finally {
            conexoes.remove(c)
            c.disconnect()
        }
    }

    /// Manda os blocos a partir de offset. Devolve a resposta final (arquivo
    /// criado) ou null se o Drive ainda pede mais (consulta de novo).
    private fun mandarBlocos(
        s: Sessao, arq: File, inicio: Long, total: Long, md: MessageDigest?, est: Estado,
    ): JSONObject? {
        var offset = inicio
        if (total == 0L) {
            val c = abrir(s.url)
            try {
                c.requestMethod = "PUT"
                c.doOutput = true
                c.setRequestProperty("Content-Range", "bytes */0")
                c.setFixedLengthStreamingMode(0)
                c.outputStream.close()
                val (cod, corpo) = ler(c)
                if (cod == 200 || cod == 201) return JSONObject(corpo ?: "{}")
                throw HttpErro(cod, corpo, true)
            } finally {
                conexoes.remove(c)
                c.disconnect()
            }
        }
        RandomAccessFile(arq, "r").use { raf ->
            val buf = ByteArray(256 * 1024)
            while (!parar) {
                val (ini, fim) = MotorUtil.proximoBloco(offset, total) ?: return null
                val tam = fim - ini + 1
                val c = abrir(s.url)
                try {
                    c.requestMethod = "PUT"
                    c.doOutput = true
                    c.setRequestProperty("Content-Range", MotorUtil.contentRange(ini, fim, total))
                    c.setFixedLengthStreamingMode(tam)
                    raf.seek(ini)
                    c.outputStream.use { out ->
                        var falta = tam
                        while (falta > 0) {
                            if (parar) throw IOException("parado")
                            val n = raf.read(buf, 0, minOf(buf.size.toLong(), falta).toInt())
                            if (n <= 0) throw IOException("arquivo encolheu")
                            out.write(buf, 0, n)
                            md?.update(buf, 0, n)
                            falta -= n
                        }
                    }
                    val (cod, corpo) = ler(c)
                    when (cod) {
                        200, 201 -> {
                            somarBytes(est, tam)
                            return JSONObject(corpo ?: "{}")
                        }
                        308 -> {
                            val rec = MotorUtil.recebidos(c.getHeaderField("Range"))
                            somarBytes(est, rec - offset)
                            if (rec != fim + 1) {
                                // O Drive guardou menos que o bloco: o MD5 em
                                // memória perdeu a sequência; volta pela consulta.
                                return null
                            }
                            offset = rec
                        }
                        else -> throw HttpErro(cod, corpo, true)
                    }
                } finally {
                    conexoes.remove(c)
                    c.disconnect()
                }
            }
        }
        throw IOException("parado")
    }

    private fun somarBytes(est: Estado, b: Long) {
        if (b <= 0) return
        val acumulado = est.bytesFeitos.addAndGet(b)
        synchronized(est.amostras) {
            val agora = System.currentTimeMillis()
            est.amostras.addLast(agora to acumulado)
            while (est.amostras.size > 2 && agora - est.amostras.first().first > 120_000) {
                est.amostras.removeFirst()
            }
        }
    }

    private fun velocidade(est: Estado): Double = synchronized(est.amostras) {
        if (est.amostras.size < 2) return 0.0
        val a = est.amostras.first()
        val b = est.amostras.last()
        val dt = (b.first - a.first) / 1000.0
        if (dt < 10) 0.0 else (b.second - a.second) / dt
    }

    private fun apagarNoDrive(fileId: String, token: Token) {
        if (fileId.isEmpty()) return
        val c = abrir("https://www.googleapis.com/drive/v3/files/$fileId")
        try {
            c.requestMethod = "DELETE"
            c.setRequestProperty("Authorization", "Bearer ${token.valor()}")
            ler(c)
        } finally {
            conexoes.remove(c)
            c.disconnect()
        }
    }

    // -------------------------------------------------------------------------
    // Token sem tela (Authorization API do Google Identity)
    // -------------------------------------------------------------------------

    private class Token(val ctx: Context, val email: String) {
        private var valor: String? = null
        private var obtidoEm = 0L

        @Synchronized
        fun valor(): String {
            val agora = System.currentTimeMillis()
            val v = valor
            // O Google entrega token de 1 h; renova com folga aos 40 min.
            if (v != null && agora - obtidoEm < 40 * 60_000) return v
            val novo = obter(ctx, email) ?: throw PrecisaLogin()
            valor = novo
            obtidoEm = agora
            return novo
        }

        @Synchronized
        fun invalidar() {
            val v = valor ?: return
            try { GoogleAuthUtil.clearToken(ctx, v) } catch (_: Exception) {}
            valor = null
        }
    }

    fun pedido(email: String): AuthorizationRequest {
        val b = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(Scope(ESCOPO)))
        if (email.isNotEmpty()) b.setAccount(Account(email, "com.google"))
        return b.build()
    }

    /// Token sem tela, ou null se precisa da pessoa (abrir o app).
    fun obter(ctx: Context, email: String): String? = try {
        val r = Tasks.await(
            Identity.getAuthorizationClient(ctx).authorize(pedido(email)), 60, TimeUnit.SECONDS)
        if (r.hasResolution()) null else r.accessToken
    } catch (e: Exception) {
        registrar(ctx, "token: $e")
        null
    }

    // -------------------------------------------------------------------------
    // Arquivos
    // -------------------------------------------------------------------------

    private val travaRes = Any()
    private val travaSess = Any()

    private fun resultadoOk(d: File, item: Item, fileId: String, bytes: Long, verificado: Boolean, est: Estado) {
        anexar(d, JSONObject().put("id", item.id).put("ok", true).put("fileId", fileId)
            .put("bytes", bytes).put("verificado", verificado).put("t", System.currentTimeMillis()))
        est.feitos.incrementAndGet()
    }

    private fun resultadoFalha(d: File, item: Item, erro: String, definitivo: Boolean, est: Estado) {
        anexar(d, JSONObject().put("id", item.id).put("ok", false).put("erro", erro)
            .put("definitivo", definitivo).put("t", System.currentTimeMillis()))
        est.falhas.incrementAndGet()
        est.ultimoErro = erro
    }

    private fun anexar(d: File, j: JSONObject) = synchronized(travaRes) {
        FileOutputStream(File(d, "resultados.jsonl"), true).use {
            it.write((j.toString() + "\n").toByteArray())
            it.fd.sync() // 1 linha por arquivo: barato, e um kill não perde o "subiu"
        }
    }

    private fun lerConcluidos(d: File): MutableSet<String> {
        val s = ConcurrentHashMap.newKeySet<String>()
        val f = File(d, "resultados.jsonl")
        if (!f.exists()) return s
        f.forEachLine { l ->
            try {
                val j = JSONObject(l)
                if (j.optBoolean("ok")) s.add(j.getString("id"))
            } catch (_: Exception) {} // linha cortada no fim (kill): ignora
        }
        return s
    }

    private fun lerFila(f: File): List<Item> {
        val j = lerJson(f) ?: return emptyList()
        val arr = j.optJSONArray("itens") ?: JSONArray()
        val res = ArrayList<Item>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val id = o.optString("id")
            val pai = o.optString("paiId")
            if (id.isEmpty() || pai.isEmpty()) continue
            res.add(Item(id, o.optString("titulo", "sem nome"), o.optString("path"),
                o.optLong("bytes"), o.optLong("data"), pai))
        }
        return res
    }

    private fun lerSessoes(d: File): MutableMap<String, Sessao> {
        val m = ConcurrentHashMap<String, Sessao>()
        val j = lerJson(File(d, "sessoes.json")) ?: return m
        val agora = System.currentTimeMillis()
        for (k in j.keys()) {
            val o = j.optJSONObject(k) ?: continue
            // A sessão do Drive vale 1 semana; com folga, 6 dias.
            if (agora - o.optLong("criado") > 6L * 86400000L) continue
            m[k] = Sessao(o.optString("url"), o.optLong("total"))
        }
        return m
    }

    private fun salvarSessoes(d: File, m: Map<String, Sessao>) = synchronized(travaSess) {
        val j = JSONObject()
        val agora = System.currentTimeMillis()
        for ((k, s) in m) j.put(k, JSONObject().put("url", s.url).put("total", s.total).put("criado", agora))
        escreverAtomico(File(d, "sessoes.json"), j.toString())
    }

    private fun gravarEstado(d: File, est: Estado, ativo: Boolean) {
        try {
            escreverAtomico(File(d, "estado.json"), JSONObject()
                .put("ativo", ativo).put("t", System.currentTimeMillis())
                .put("total", est.total.get()).put("feitos", est.feitos.get())
                .put("falhas", est.falhas.get())
                .put("bytesTotal", est.bytesTotal.get()).put("bytesFeitos", est.bytesFeitos.get())
                .put("bytesPorSeg", velocidade(est))
                .put("semRede", est.semRede).put("precisaLogin", est.precisaLogin)
                .put("driveCheio", est.driveCheio).put("ultimoErro", est.ultimoErro ?: "")
                .toString())
        } catch (_: Exception) {}
    }

    private fun lerJson(f: File): JSONObject? = try {
        if (f.exists()) JSONObject(f.readText()) else null
    } catch (_: Exception) { null }

    fun escreverAtomico(f: File, texto: String) {
        val tmp = File(f.parentFile, f.name + ".tmp")
        FileOutputStream(tmp).use {
            it.write(texto.toByteArray())
            it.fd.sync()
        }
        if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
    }

    fun registrar(ctx: Context, texto: String) {
        try {
            val f = File(dir(ctx), "diario.log")
            if (f.length() > 512 * 1024) f.delete()
            f.appendText("${System.currentTimeMillis()} $texto\n")
        } catch (_: Exception) {}
    }

    // -------------------------------------------------------------------------
    // Rede, MD5, tipo
    // -------------------------------------------------------------------------

    private fun temRede(ctx: Context, soWifi: Boolean): Boolean = try {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            (!soWifi || caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
    } catch (_: Exception) { true }

    private fun md5Arquivo(f: File): String? = try {
        val md = MessageDigest.getInstance("MD5")
        FileInputStream(f).use { fis ->
            val buf = ByteArray(1 shl 17)
            while (true) {
                val n = fis.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        hex(md.digest())
    } catch (_: Exception) { null }

    private fun hex(b: ByteArray): String {
        val sb = StringBuilder(32)
        for (x in b) {
            val v = x.toInt() and 0xff
            if (v < 16) sb.append('0')
            sb.append(Integer.toHexString(v))
        }
        return sb.toString()
    }

    private fun mime(nome: String): String {
        val ext = nome.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    private fun dormir(ms: Long) {
        var falta = ms
        while (falta > 0 && !parar) {
            Thread.sleep(minOf(falta, 1000))
            falta -= 1000
        }
    }

    // -------------------------------------------------------------------------
    // Notificação única (A-20)
    // -------------------------------------------------------------------------

    fun canal(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CANAL, "Backup", NotificationManager.IMPORTANCE_LOW))
    }

    private fun abrirApp(ctx: Context): PendingIntent? = try {
        val i = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        i?.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        if (i == null) null else PendingIntent.getActivity(ctx, 0, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    } catch (_: Exception) { null }

    private fun builder(ctx: Context): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CANAL)
        else @Suppress("DEPRECATION") Notification.Builder(ctx)

    fun notificacaoInicial(ctx: Context): Notification {
        canal(ctx)
        return builder(ctx).setContentTitle("Backup")
            .setContentText("Preparando…")
            .setSmallIcon(ctx.applicationInfo.icon)
            .setOngoing(true).setOnlyAlertOnce(true)
            .setContentIntent(abrirApp(ctx))
            .build()
    }

    private fun notificacao(ctx: Context, est: Estado, emCurso: Boolean): Notification {
        val total = est.total.get()
        val feitos = est.feitos.get().coerceAtMost(total)
        val texto = when {
            est.precisaLogin -> "Abra o app pra continuar"
            est.semRede -> "Sem internet: continua sozinho quando a rede voltar"
            else -> MotorUtil.eta(est.bytesTotal.get() - est.bytesFeitos.get(), velocidade(est))
                .ifEmpty { "Subindo…" }
        }
        return builder(ctx)
            .setContentTitle("Backup: ${milhar(feitos)} de ${milhar(total)}")
            .setContentText(texto)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setOngoing(emCurso).setOnlyAlertOnce(true)
            .setProgress(total.coerceAtLeast(1), feitos, total == 0)
            .setContentIntent(abrirApp(ctx))
            .build()
    }

    private fun notificarFim(ctx: Context, est: Estado, acabou: Boolean) {
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val (titulo, texto) = when {
                est.driveCheio -> "Backup pausado" to "O Drive encheu. Abra o app pra ver o que fazer."
                est.precisaLogin -> "Backup pausado" to "O Google pediu pra confirmar a conta. Abra o app."
                acabou && est.feitos.get() > 0 ->
                    "Backup concluído" to "${milhar(est.feitos.get())} arquivos seguros no Drive." +
                        (if (est.falhas.get() > 0) " ${milhar(est.falhas.get())} não subiram." else "")
                else -> return
            }
            nm.notify(ID_NOTIF_FIM, builder(ctx).setContentTitle(titulo).setContentText(texto)
                .setSmallIcon(ctx.applicationInfo.icon).setAutoCancel(true)
                .setContentIntent(abrirApp(ctx)).build())
        } catch (_: Exception) {}
    }

    private fun milhar(n: Int): String = String.format(java.util.Locale.forLanguageTag("pt-BR"), "%,d", n)
}

/// UIDT (Android 14+): trabalho longo iniciado pela pessoa, sem o teto de 6 h.
class MotorJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 34) {
            setNotification(params, MotorNativo.ID_NOTIF, MotorNativo.notificacaoInicial(this),
                JobService.JOB_END_NOTIFICATION_POLICY_REMOVE)
        }
        MotorNativo.rodar(this,
            aoNotificar = { n -> try { nm.notify(MotorNativo.ID_NOTIF, n) } catch (_: Exception) {} },
            aoTerminar = { reagendar -> jobFinished(params, reagendar) })
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        MotorNativo.interromper()
        return !MotorNativo.paradoPeloUsuario
    }
}

/// Abaixo do Android 14: serviço em primeiro plano (dataSync).
class MotorService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = MotorNativo.notificacaoInicial(this)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(MotorNativo.ID_NOTIF, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(MotorNativo.ID_NOTIF, n)
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        MotorNativo.rodar(this,
            aoNotificar = { x -> try { nm.notify(MotorNativo.ID_NOTIF, x) } catch (_: Exception) {} },
            aoTerminar = { _ ->
                if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
                else @Suppress("DEPRECATION") stopForeground(true)
                stopSelf()
            })
        return START_STICKY
    }

    override fun onDestroy() {
        MotorNativo.interromper()
        super.onDestroy()
    }
}
