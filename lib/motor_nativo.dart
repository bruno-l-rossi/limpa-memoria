import 'dart:convert';
import 'dart:io';

import 'modelos.dart';

/// Lado Dart do motor nativo (rodada 19, F4). O motor em Kotlin
/// (MotorNativo.kt) sobe com o app fechado; os dois conversam por arquivos em
/// `<dados do app>/motor/`, cada um com 1 escritor só:
///   fila.json         o app escreve (o que subir)
///   resultados.jsonl  o motor escreve (1 linha por arquivo)
///   estado.json       o motor escreve (progresso)
/// Testes em test/motor_nativo_test.dart.

/// Um arquivo entregue ao motor, com a pasta do Drive já resolvida.
class ItemNativo {
  final ItemBackup item;
  final String paiId;
  const ItemNativo(this.item, this.paiId);

  Map<String, Object> toJson() => {
        'id': item.id,
        'titulo': item.titulo,
        'path': item.path,
        'bytes': item.bytes,
        'data': item.data,
        'paiId': paiId,
      };
}

/// Uma linha de resultados.jsonl.
class ResultadoNativo {
  final String id;
  final bool ok;
  final String? fileId;
  final int? bytes;
  final bool verificado;
  final String erro;
  final bool definitivo;
  const ResultadoNativo(this.id, this.ok,
      {this.fileId,
      this.bytes,
      this.verificado = false,
      this.erro = '',
      this.definitivo = false});

  bool get driveCheio => !ok && erro == 'drive_cheio';

  static ResultadoNativo? de(String linha) {
    try {
      final j = jsonDecode(linha);
      if (j is! Map) return null;
      final id = j['id'];
      if (id is! String || id.isEmpty) return null;
      final fid = j['fileId'];
      return ResultadoNativo(
        id,
        j['ok'] == true,
        fileId: fid is String && fid.isNotEmpty ? fid : null,
        bytes: (j['bytes'] as num?)?.toInt(),
        verificado: j['verificado'] == true,
        erro: (j['erro'] as String?) ?? '',
        definitivo: j['definitivo'] == true,
      );
    } catch (_) {
      return null; // linha cortada no fim (kill no meio da escrita)
    }
  }
}

/// Progresso que o motor grava a cada ~2 s.
class EstadoNativo {
  final bool ativo;
  final DateTime em;
  final int total, feitos, falhas;
  final int bytesTotal, bytesFeitos;
  final double bytesPorSeg;
  final bool semRede, precisaLogin, driveCheio;
  final String ultimoErro;
  const EstadoNativo({
    this.ativo = false,
    required this.em,
    this.total = 0,
    this.feitos = 0,
    this.falhas = 0,
    this.bytesTotal = 0,
    this.bytesFeitos = 0,
    this.bytesPorSeg = 0,
    this.semRede = false,
    this.precisaLogin = false,
    this.driveCheio = false,
    this.ultimoErro = '',
  });

  /// Rodando de verdade: diz que está ativo E escreveu há pouco (um kill
  /// deixa "ativo" gravado pra sempre).
  bool vivo(DateTime agora) =>
      ativo && agora.difference(em) < const Duration(minutes: 2);

  static EstadoNativo? de(String texto) {
    try {
      final j = jsonDecode(texto);
      if (j is! Map) return null;
      int n(String k) => (j[k] as num?)?.toInt() ?? 0;
      return EstadoNativo(
        ativo: j['ativo'] == true,
        em: DateTime.fromMillisecondsSinceEpoch(n('t')),
        total: n('total'),
        feitos: n('feitos'),
        falhas: n('falhas'),
        bytesTotal: n('bytesTotal'),
        bytesFeitos: n('bytesFeitos'),
        bytesPorSeg: (j['bytesPorSeg'] as num?)?.toDouble() ?? 0,
        semRede: j['semRede'] == true,
        precisaLogin: j['precisaLogin'] == true,
        driveCheio: j['driveCheio'] == true,
        ultimoErro: (j['ultimoErro'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Arquivos do motor numa pasta (a de dados do app em produção, uma
/// temporária nos testes).
class ArquivosMotor {
  final Directory dir;
  ArquivosMotor(String base) : dir = Directory('$base/motor');

  File get _fila => File('${dir.path}/fila.json');
  File get _resultados => File('${dir.path}/resultados.jsonl');
  File get _estado => File('${dir.path}/estado.json');

  /// Escreve a fila inteira de uma vez (temporário + rename: o motor nunca lê
  /// um arquivo pela metade). `lido` diz até onde o app já leu o
  /// resultados.jsonl (geração e offset): só com isso o motor pode recomeçar
  /// aquele arquivo (rodada 20).
  Future<void> escreverFila(Iterable<ItemNativo> itens,
      {({int geracao, int offset})? lido}) async {
    await dir.create(recursive: true);
    final tmp = File('${_fila.path}.tmp');
    await tmp.writeAsString(
        jsonEncode({
          'itens': [for (final i in itens) i.toJson()],
          if (lido != null)
            'lido': {'geracao': lido.geracao, 'offset': lido.offset},
        }),
        flush: true);
    await tmp.rename(_fila.path);
  }

  /// Geração do resultados.jsonl (1ª linha {"geracao": N}); 0 sem cabeçalho,
  /// -1 se o arquivo não existe.
  Future<int> geracao() async {
    try {
      if (!await _resultados.exists()) return -1;
      final raf = await _resultados.open();
      try {
        final ini = await raf.read(256);
        final i = ini.indexOf(10);
        if (i < 0) return 0;
        final j = jsonDecode(utf8.decode(ini.sublist(0, i), allowMalformed: true));
        return j is Map && j['geracao'] is num ? (j['geracao'] as num).toInt() : 0;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return 0;
    }
  }

  /// Resultados novos a partir de `offset` (bytes). Devolve os resultados e o
  /// offset novo. Linha sem "\n" no fim (o motor ainda escrevendo) fica pra
  /// próxima leitura.
  Future<(List<ResultadoNativo>, int)> lerResultados(int offset) async {
    if (!await _resultados.exists()) return (const <ResultadoNativo>[], 0);
    final tam = await _resultados.length();
    // Arquivo menor que o offset: foi recriado. Lê do começo.
    var ini = tam < offset ? 0 : offset;
    if (tam == ini) return (const <ResultadoNativo>[], ini);
    final raf = await _resultados.open();
    try {
      await raf.setPosition(ini);
      final bytes = await raf.read(tam - ini);
      final ultimaQuebra = bytes.lastIndexOf(10);
      if (ultimaQuebra < 0) return (const <ResultadoNativo>[], ini);
      final texto = utf8.decode(bytes.sublist(0, ultimaQuebra + 1),
          allowMalformed: true);
      final res = <ResultadoNativo>[];
      for (final l in const LineSplitter().convert(texto)) {
        final r = ResultadoNativo.de(l);
        if (r != null) res.add(r);
      }
      return (res, ini + ultimaQuebra + 1);
    } finally {
      await raf.close();
    }
  }

  Future<EstadoNativo?> lerEstado() async {
    try {
      if (!await _estado.exists()) return null;
      return EstadoNativo.de(await _estado.readAsString());
    } catch (_) {
      return null;
    }
  }
}
