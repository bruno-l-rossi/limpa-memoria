package com.rideblan.limpa_memoria

/// Regras puras do motor nativo (rodada 19, F4). Sem Android aqui dentro:
/// testadas em android/app/src/test (JUnit).
object MotorUtil {
    /// Bloco de upload: 8 MiB. O Drive exige múltiplo de 256 KiB em todo bloco
    /// menos o último.
    const val BLOCO = 8L * 1024 * 1024

    /// Próximo bloco a mandar: (início, fim inclusivo). null = nada a mandar.
    fun proximoBloco(offset: Long, total: Long, bloco: Long = BLOCO): Pair<Long, Long>? {
        if (total <= 0 || offset >= total) return null
        val fim = minOf(offset + bloco, total) - 1
        return offset to fim
    }

    /// Cabeçalho Content-Range de um bloco ("bytes 0-8388607/20000000").
    fun contentRange(ini: Long, fim: Long, total: Long): String = "bytes $ini-$fim/$total"

    /// Cabeçalho pra perguntar ao Drive quanto chegou ("bytes */total").
    fun contentRangeConsulta(total: Long): String = "bytes */$total"

    /// Lê o Range da resposta 308 ("bytes=0-12345") e devolve quantos bytes o
    /// Drive já tem (12346). Sem Range = nada chegou (0).
    fun recebidos(range: String?): Long {
        if (range.isNullOrBlank()) return 0
        val m = Regex("""bytes=0-(\d+)""").find(range) ?: return 0
        return (m.groupValues[1].toLongOrNull() ?: -1) + 1
    }

    /// Espera antes da tentativa n (1, 2, 3...): 5 s, 15 s, 45 s... até 10 min.
    fun esperaMs(tentativa: Int): Long {
        var s = 5L
        repeat((tentativa - 1).coerceAtLeast(0)) { s = (s * 3).coerceAtMost(600) }
        return s * 1000
    }

    /// Tipo de resposta ruim do Drive.
    enum class Erro { REDE, TOKEN, DRIVE_CHEIO, TAXA, SESSAO_EXPIROU, DEFINITIVO }

    /// Classifica um código HTTP (e o corpo, pro 403) num tipo de erro.
    fun classificar(codigo: Int, corpo: String?, naSessao: Boolean): Erro {
        val c = corpo ?: ""
        return when {
            codigo == 401 -> Erro.TOKEN
            codigo == 403 && c.contains("storageQuotaExceeded") -> Erro.DRIVE_CHEIO
            codigo == 403 && (c.contains("ateLimitExceeded") || c.contains("rateLimit")) -> Erro.TAXA
            codigo == 429 || codigo >= 500 -> Erro.TAXA
            naSessao && (codigo == 404 || codigo == 410) -> Erro.SESSAO_EXPIROU
            else -> Erro.DEFINITIVO
        }
    }

    /// Data em ISO 8601 UTC pro Drive, ou null se a data é inválida (mesma
    /// regra do Dart: depois de 1990 e no máximo 2 dias no futuro).
    fun dataIso(ms: Long, agora: Long = System.currentTimeMillis()): String? {
        val minimo = 631152000000L // 1990-01-01
        if (ms <= minimo || ms >= agora + 2L * 86400000L) return null
        val f = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
        f.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return f.format(java.util.Date(ms))
    }

    /// Escapa texto pra JSON (nome do arquivo no metadado).
    fun json(s: String): String {
        val sb = StringBuilder("\"")
        for (ch in s) {
            when (ch) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (ch < ' ') sb.append(String.format("\\u%04x", ch.code)) else sb.append(ch)
            }
        }
        return sb.append('"').toString()
    }

    /// Metadado do arquivo novo no Drive.
    fun metadado(nome: String, paiId: String, dataMs: Long, agora: Long = System.currentTimeMillis()): String {
        val d = dataIso(dataMs, agora)
        val datas = if (d != null) ""","createdTime":"$d","modifiedTime":"$d"""" else ""
        return """{"name":${json(nome)},"parents":[${json(paiId)}]$datas}"""
    }

    /// Até este tamanho o arquivo sobe num pedido só (multipart), sem abrir
    /// sessão: metade das idas ao Drive pra foto pequena (rodada 20, A-13a).
    const val TETO_MULTIPART = 5L * 1024 * 1024

    /// Consulta do Drive por nome dentro de uma pasta (pra não duplicar quando
    /// um pedido multipart caiu sem resposta).
    fun qBusca(nome: String, paiId: String): String {
        fun esc(x: String) = x.replace("\\", "\\\\").replace("'", "\\'")
        return "name='${esc(nome)}' and '${esc(paiId)}' in parents and trashed=false"
    }

    /// Começo e fim do corpo multipart/related (o conteúdo vai no meio).
    fun multipartInicio(fronteira: String, metadado: String, mime: String): String =
        "--$fronteira\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadado\r\n" +
            "--$fronteira\r\nContent-Type: $mime\r\n\r\n"

    fun multipartFim(fronteira: String): String = "\r\n--$fronteira--\r\n"

    /// Pode limpar o resultados.jsonl? Só se o app já leu tudo desta geração.
    fun podeRotacionar(geracaoArquivo: Long, tamanho: Long, lidoGeracao: Long, lidoOffset: Long,
                       minimo: Long = 256 * 1024): Boolean =
        tamanho >= minimo && lidoGeracao == geracaoArquivo && lidoOffset == tamanho

    /// Texto de estimativa pra notificação ("~2h10 restantes").
    fun eta(bytesRestantes: Long, bytesPorSeg: Double): String {
        if (bytesPorSeg <= 0 || bytesRestantes <= 0) return ""
        val s = (bytesRestantes / bytesPorSeg).toLong()
        if (s < 60) return "menos de 1 min"
        val h = s / 3600
        val m = (s % 3600) / 60
        return if (h > 0) "~${h}h${m.toString().padStart(2, '0')} restantes" else "~$m min restantes"
    }
}
