package com.rideblan.limpa_memoria

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MotorUtilTest {
    private val mib = 1024L * 1024

    @Test
    fun blocosCobremOArquivoTodoSemSobra() {
        val total = 20 * mib + 123
        var off = 0L
        val blocos = mutableListOf<Pair<Long, Long>>()
        while (true) {
            val b = MotorUtil.proximoBloco(off, total) ?: break
            blocos += b
            off = b.second + 1
        }
        assertEquals(3, blocos.size)
        assertEquals(0L to 8 * mib - 1, blocos[0])
        assertEquals(total - 1, blocos.last().second)
        // Todo bloco menos o último é múltiplo de 256 KiB.
        for (b in blocos.dropLast(1)) assertEquals(0L, (b.second - b.first + 1) % (256 * 1024))
    }

    @Test
    fun semBlocoQuandoAcabouOuVazio() {
        assertNull(MotorUtil.proximoBloco(10, 10))
        assertNull(MotorUtil.proximoBloco(0, 0))
    }

    @Test
    fun leORangeDo308() {
        assertEquals(12346L, MotorUtil.recebidos("bytes=0-12345"))
        assertEquals(0L, MotorUtil.recebidos(null))
        assertEquals(0L, MotorUtil.recebidos(""))
    }

    @Test
    fun classificaErros() {
        assertEquals(MotorUtil.Erro.TOKEN, MotorUtil.classificar(401, null, false))
        assertEquals(MotorUtil.Erro.DRIVE_CHEIO,
            MotorUtil.classificar(403, """{"reason":"storageQuotaExceeded"}""", true))
        assertEquals(MotorUtil.Erro.TAXA,
            MotorUtil.classificar(403, """{"reason":"userRateLimitExceeded"}""", true))
        assertEquals(MotorUtil.Erro.TAXA, MotorUtil.classificar(503, null, true))
        assertEquals(MotorUtil.Erro.SESSAO_EXPIROU, MotorUtil.classificar(404, null, true))
        assertEquals(MotorUtil.Erro.DEFINITIVO, MotorUtil.classificar(404, null, false))
        assertEquals(MotorUtil.Erro.DEFINITIVO, MotorUtil.classificar(400, null, false))
    }

    @Test
    fun esperaCresceAteOTeto() {
        assertEquals(5000L, MotorUtil.esperaMs(1))
        assertEquals(15000L, MotorUtil.esperaMs(2))
        assertEquals(600000L, MotorUtil.esperaMs(20))
    }

    @Test
    fun metadadoComDataEEscapes() {
        val agora = 1_790_000_000_000L
        val m = MotorUtil.metadado("foto \"1\".jpg", "pai1", 1_620_000_000_000L, agora)
        assertTrue(m.contains(""""name":"foto \"1\".jpg""""))
        assertTrue(m.contains(""""parents":["pai1"]"""))
        assertTrue(m.contains(""""createdTime":"2021-05-03T00:00:00.000Z""""))
        val semData = MotorUtil.metadado("a.jpg", "p", 0, agora)
        assertTrue(!semData.contains("createdTime"))
    }

    @Test
    fun eta() {
        assertEquals("", MotorUtil.eta(100, 0.0))
        assertEquals("~2 min restantes", MotorUtil.eta(120 * 1000, 1000.0))
        assertEquals("~1h05 restantes", MotorUtil.eta(3900 * 1000, 1000.0))
    }

    @Test
    fun buscaEscapaAspas() {
        assertEquals("name='d\\'água.jpg' and 'p1' in parents and trashed=false",
            MotorUtil.qBusca("d'água.jpg", "p1"))
    }

    @Test
    fun multipartBemFormado() {
        val ini = MotorUtil.multipartInicio("b1", "{}", "image/jpeg")
        assertTrue(ini.startsWith("--b1\r\nContent-Type: application/json"))
        assertTrue(ini.endsWith("Content-Type: image/jpeg\r\n\r\n"))
        assertEquals("\r\n--b1--\r\n", MotorUtil.multipartFim("b1"))
    }

    @Test
    fun rotacionaSoQuandoOAppLeuTudo() {
        assertTrue(MotorUtil.podeRotacionar(7, 300_000, 7, 300_000))
        // app leu menos: não pode (perderia o "subiu" de alguém)
        assertTrue(!MotorUtil.podeRotacionar(7, 300_000, 7, 299_000))
        // geração diferente: não pode
        assertTrue(!MotorUtil.podeRotacionar(7, 300_000, 6, 300_000))
        // pequeno: não vale a pena
        assertTrue(!MotorUtil.podeRotacionar(7, 1000, 7, 1000))
    }
}
