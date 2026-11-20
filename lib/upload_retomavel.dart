import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Upload retomável DE VERDADE (rodada 15, motor novo experimental).
///
/// O motor antigo manda cada arquivo num PUT único: se a rede cai em 90% de
/// um vídeo de 4 GB, recomeça do byte 0, e o Parar abandona tudo. Aqui o
/// arquivo vai em partes (Content-Range) pra mesma sessão do Drive, e a URL
/// da sessão + quanto já foi ficam salvos em disco. Rede caiu, app fechou,
/// usuário parou: na volta pergunta ao Drive quanto chegou e continua dali.
///
/// Protocolo: https://developers.google.com/drive/api/guides/manage-uploads#resumable
/// - PUT com "Content-Range: bytes INI-FIM/TOTAL" por parte;
/// - 308 = parte recebida, header Range diz até onde chegou;
/// - 200/201 = terminou, corpo traz id/size/md5Checksum;
/// - PUT vazio com "Content-Range: bytes */TOTAL" consulta o progresso;
/// - 404/410 = sessão expirou (dura cerca de 1 semana): cria outra.

/// Tamanho de cada parte. Tem que ser múltiplo de 256 KB (regra do Drive).
const int tamanhoParte = 16 * 1024 * 1024;

/// "bytes=0-1048575" -> 1048576 (próximo byte a mandar). Sem header -> 0.
int proximoByte(String? range) {
  if (range == null || range.isEmpty) return 0;
  final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
  if (m == null) return 0;
  return int.parse(m.group(2)!) + 1;
}

/// Fim (inclusivo) da parte que começa em [inicio].
int fimDaParte(int inicio, int total, {int parte = tamanhoParte}) {
  final fim = inicio + parte - 1;
  return fim >= total ? total - 1 : fim;
}

class SessaoSalva {
  final String url;
  final int total;
  final int criadaEm; // ms
  int enviado;
  SessaoSalva(this.url, this.total, this.criadaEm, this.enviado);

  Map<String, Object> toJson() =>
      {'u': url, 't': total, 'c': criadaEm, 'e': enviado};

  static SessaoSalva? fromJson(Object? j) {
    if (j is! Map) return null;
    final u = j['u'], t = j['t'], c = j['c'], e = j['e'];
    if (u is! String || t is! int || c is! int || e is! int) return null;
    return SessaoSalva(u, t, c, e);
  }

  /// Sessões do Drive valem ~1 semana; usa até 6 dias pra ter folga.
  bool get valida =>
      DateTime.now().millisecondsSinceEpoch - criadaEm <
      const Duration(days: 6).inMilliseconds;
}

enum FimUpload { ok, rede, sessaoInvalida, cancelado, erro }

class ResultadoRetomavel {
  final FimUpload fim;
  final String? fileId;
  final int? bytes;
  final String? md5;
  final String? erro;
  const ResultadoRetomavel(this.fim,
      {this.fileId, this.bytes, this.md5, this.erro});
}

class UploadRetomavel {
  final String dirDados;
  final http.Client _cliente;
  final int parte;
  final Duration esperaBase; // espera entre retentativas (teste usa zero)
  UploadRetomavel(this.dirDados,
      {http.Client? cliente,
      this.parte = tamanhoParte,
      this.esperaBase = const Duration(seconds: 2)})
      : _cliente = cliente ?? http.Client();

  File get _arquivo => File('$dirDados/sessoes_upload.json');
  Map<String, SessaoSalva>? _sessoes;
  Future<void> _gravando = Future.value();

  Future<Map<String, SessaoSalva>> _carregar() async {
    if (_sessoes != null) return _sessoes!;
    final m = <String, SessaoSalva>{};
    try {
      if (await _arquivo.exists()) {
        final j = jsonDecode(await _arquivo.readAsString()) as Map;
        j.forEach((k, v) {
          final s = SessaoSalva.fromJson(v);
          if (s != null && s.valida) m['$k'] = s;
        });
      }
    } catch (_) {}
    return _sessoes = m;
  }

  Future<void> _salvar() {
    final copia = {
      for (final e in (_sessoes ?? const <String, SessaoSalva>{}).entries)
        e.key: e.value.toJson()
    };
    _gravando = _gravando.then((_) async {
      try {
        final tmp = File('${_arquivo.path}.tmp');
        await tmp.writeAsString(jsonEncode(copia), flush: true);
        await tmp.rename(_arquivo.path);
      } catch (_) {}
    });
    return _gravando;
  }

  Future<void> esquecer(String id) async {
    final m = await _carregar();
    if (m.remove(id) != null) await _salvar();
  }

  /// Quanto já foi de um item (pra mostrar "continua de 1,2 GB").
  Future<int> jaEnviado(String id) async => (await _carregar())[id]?.enviado ?? 0;

  /// Sobe [caminho] como o item [id]. [criarSessao] abre uma sessão nova no
  /// Drive (devolve a URL ou null + erro). [cancelado] é consultado entre as
  /// partes (Parar). [progresso] recebe bytes confirmados pelo Drive.
  Future<ResultadoRetomavel> enviar(
    String id,
    String caminho, {
    required Future<(String?, String?)> Function() criarSessao,
    bool Function()? cancelado,
    void Function(int enviado, int total)? progresso,
  }) async {
    final arq = File(caminho);
    final int total;
    try {
      total = await arq.length();
    } catch (e) {
      return ResultadoRetomavel(FimUpload.erro, erro: 'não abriu o arquivo: $e');
    }
    if (total <= 0) {
      return const ResultadoRetomavel(FimUpload.erro, erro: 'arquivo vazio');
    }
    final sessoes = await _carregar();
    var s = sessoes[id];
    if (s != null && (s.total != total || !s.valida)) {
      // Arquivo mudou de tamanho ou sessão velha: começa de novo.
      sessoes.remove(id);
      s = null;
    }

    // Retomando: pergunta ao Drive quanto chegou de fato.
    if (s != null) {
      final r = await _consultar(s);
      if (r != null) return await _fimOk(id, r);
      if (s.enviado < 0) {
        sessoes.remove(id);
        s = null; // sessão inválida
      }
    }

    if (s == null) {
      final (url, erro) = await criarSessao();
      if (url == null) {
        final rede = erro != null && erro.startsWith('rede: ');
        return ResultadoRetomavel(rede ? FimUpload.rede : FimUpload.erro,
            erro: erro);
      }
      s = SessaoSalva(url, total, DateTime.now().millisecondsSinceEpoch, 0);
      sessoes[id] = s;
      await _salvar();
    }

    RandomAccessFile? raf;
    try {
      raf = await arq.open();
      var falhasSeguidas = 0;
      while (s.enviado < total) {
        if (cancelado?.call() ?? false) {
          await _salvar();
          return const ResultadoRetomavel(FimUpload.cancelado);
        }
        final ini = s.enviado;
        final fim = fimDaParte(ini, total, parte: parte);
        await raf.setPosition(ini);
        final dados = await raf.read(fim - ini + 1);
        http.Response resp;
        try {
          resp = await _cliente
              .put(Uri.parse(s.url),
                  headers: {'Content-Range': 'bytes $ini-$fim/$total'},
                  body: dados)
              .timeout(const Duration(minutes: 3));
        } catch (e) {
          // Queda no meio da parte: pergunta onde parou e tenta de novo.
          falhasSeguidas++;
          if (falhasSeguidas > 4) {
            await _salvar();
            return ResultadoRetomavel(FimUpload.rede, erro: 'rede: $e');
          }
          await Future.delayed(esperaBase * (1 << falhasSeguidas));
          final r = await _consultar(s);
          if (r != null) return await _fimOk(id, r);
          if (s.enviado < 0) return await _invalida(id);
          continue;
        }
        final code = resp.statusCode;
        if (code == 308) {
          falhasSeguidas = 0;
          s.enviado = proximoByte(resp.headers['range']);
          await _salvar();
          progresso?.call(s.enviado, total);
          continue;
        }
        if (code == 200 || code == 201) {
          return await _fimOk(id, resp.body);
        }
        if (code == 404 || code == 410) return await _invalida(id);
        if (code == 429 || code >= 500) {
          falhasSeguidas++;
          if (falhasSeguidas > 4) {
            await _salvar();
            return ResultadoRetomavel(FimUpload.rede,
                erro: 'rede: Drive pediu pra esperar (HTTP $code)');
          }
          await Future.delayed(esperaBase * (1 << falhasSeguidas));
          final r = await _consultar(s);
          if (r != null) return await _fimOk(id, r);
          if (s.enviado < 0) return await _invalida(id);
          continue;
        }
        // Outro 4xx: sessão não serve mais.
        await esquecer(id);
        return ResultadoRetomavel(FimUpload.erro,
            erro: 'Drive recusou a parte (HTTP $code)');
      }
      // Mandou tudo mas não veio a resposta final: consulta.
      final r = await _consultar(s);
      if (r != null) return await _fimOk(id, r);
      await _salvar();
      return const ResultadoRetomavel(FimUpload.rede,
          erro: 'rede: terminou sem resposta do Drive');
    } catch (e) {
      await _salvar();
      return ResultadoRetomavel(FimUpload.erro, erro: '$e');
    } finally {
      await raf?.close();
    }
  }

  Future<ResultadoRetomavel> _invalida(String id) async {
    await esquecer(id);
    return const ResultadoRetomavel(FimUpload.sessaoInvalida,
        erro: 'rede: sessão do Drive expirou, recomeçando');
  }

  /// Consulta o progresso. Devolve o corpo final se o upload já terminou;
  /// senão atualiza s.enviado (-1 = sessão inválida) e devolve null.
  Future<String?> _consultar(SessaoSalva s) async {
    try {
      final resp = await _cliente.put(Uri.parse(s.url),
          headers: {'Content-Range': 'bytes */${s.total}'},
          body: const <int>[]).timeout(const Duration(seconds: 30));
      final code = resp.statusCode;
      if (code == 200 || code == 201) return resp.body;
      if (code == 308) {
        s.enviado = proximoByte(resp.headers['range']);
      } else if (code == 404 || code == 410 || (code >= 400 && code < 500)) {
        s.enviado = -1;
      }
    } catch (_) {
      // sem rede: mantém o que sabia
    }
    return null;
  }

  Future<ResultadoRetomavel> _fimOk(String id, String corpo) async {
    await esquecer(id);
    try {
      final m = jsonDecode(corpo) as Map;
      return ResultadoRetomavel(FimUpload.ok,
          fileId: m['id']?.toString(),
          bytes: int.tryParse(m['size']?.toString() ?? ''),
          md5: m['md5Checksum']?.toString());
    } catch (_) {
      return const ResultadoRetomavel(FimUpload.ok);
    }
  }
}
