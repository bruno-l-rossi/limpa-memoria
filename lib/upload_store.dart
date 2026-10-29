import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
import 'package:shared_preferences/shared_preferences.dart';

/// O que sabemos de um arquivo já enviado: o id do arquivo no Drive (pra
/// conferir antes de apagar do celular) e o tamanho em bytes.
class EnvioInfo {
  final String? fileId;
  final int? bytes;
  const EnvioInfo({this.fileId, this.bytes});
}

/// Um envio pra gravar em lote: id local, fileId no Drive, tamanho.
typedef NovoEnvio = ({String id, String? fileId, int? bytes});

/// Persistência no celular do que já subiu e do backup em andamento.
///
/// Arquivos próprios na pasta de dados do app (rodada 8):
///
/// - enviados.jsonl: UMA LINHA por arquivo enviado, em append. Gravar um envio
///   custa uma linha, não o arquivo inteiro. Sobrevive a kill no meio (a linha
///   ou entrou ou não entrou; nunca corrompe o resto).
/// - job.json: o backup pedido pelo usuário. Escrita atômica (tmp + rename).
/// - tamanhos.json: cache de tamanhos SÓ dos fallbacks (a fonte principal é o
///   MediaStore via canal nativo, numa consulta só).
///
/// Rodada 10 (volume grande):
/// - leitura e escrita pesadas (30 mil linhas, job de MBs) rodam num isolate
///   separado: a tela não congela no boot nem ao salvar o job;
/// - o job fica em memória (ler/decodificar MBs a cada Subir/Retomar era
///   desperdício) e as escritas dele são serializadas (duas gravações ao mesmo
///   tempo disputavam o mesmo .tmp);
/// - gravação em LOTE (reconhecer backup antigo, reconciliação do boot e
///   duplicatas faziam milhares de appends com flush, um por um);
/// - enviados.jsonl é compactado no boot quando acumula linhas repetidas.
///
/// Flags pequenas (pausado, wifi, migrações) continuam no SharedPreferences.
class UploadStore {
  static const _kPausado = 'backup_pausado';
  static const _kWifi = 'so_wifi';
  static const _kMigrouJanela = 'migrou_janela_v1';
  static const _kMigrouArquivos = 'migrou_arquivos_v1';
  // Chaves antigas (SharedPreferences), lidas só na migração única.
  static const _kEnviadosLegado = 'ids_enviados';
  static const _kJobLegado = 'job_pendente';
  static const _kTamanhosLegado = 'tamanhos_cache';

  Directory? _dir;
  final Map<String, EnvioInfo> _enviados = {};
  Map<String, int>? _tamCache;
  List<Map<String, String>>? _job; // cache em memória do job.json
  // Fila de escrita dos appends: um após o outro, cada um com flush.
  Future<void> _filaEscrita = Future.value();
  // Fila das escritas atômicas (job, tamanhos, compactação).
  Future<void> _filaAtomica = Future.value();
  Future<void>? _iniciando;

  File get _fEnviados => File('${_dir!.path}/enviados.jsonl');
  File get _fJob => File('${_dir!.path}/job.json');
  File get _fTamanhos => File('${_dir!.path}/tamanhos.json');
  File get _fSessoes => File('${_dir!.path}/sessoes.jsonl');

  /// Chamar no boot, antes de qualquer leitura. Idempotente e seguro de
  /// chamar em paralelo (a segunda chamada espera a primeira).
  Future<void> init(String? dirDados) => _iniciando ??= _init(dirDados);

  Future<void> _init(String? dirDados) async {
    if (dirDados == null || dirDados.isEmpty) {
      // Sem canal nativo (não deveria acontecer no Android). Segue só com o
      // legado do SharedPreferences pra não perder o histórico.
      await _carregarLegado();
      return;
    }
    _dir = Directory(dirDados);
    try {
      if (!await _dir!.exists()) await _dir!.create(recursive: true);
    } catch (_) {}
    try {
      await _migrarSePrecisar();
    } catch (_) {}
    await _carregarEnviados();
    await _carregarJob();
  }

  Future<void> _migrarSePrecisar() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_kMigrouArquivos) ?? false) return;
    // Enviados antigos viram linhas (sem fileId/bytes; são o legado).
    final antigos = p.getStringList(_kEnviadosLegado) ?? const <String>[];
    if (antigos.isNotEmpty && !await _fEnviados.exists()) {
      final buf = StringBuffer();
      for (final id in antigos) {
        buf.writeln(jsonEncode({'id': id}));
      }
      await _fEnviados.writeAsString(buf.toString(), flush: true);
    }
    // Job e tamanhos antigos viram os arquivos novos.
    final jobRaw = p.getString(_kJobLegado);
    if (jobRaw != null && jobRaw.isNotEmpty && !await _fJob.exists()) {
      await _gravarAtomico(_fJob, jobRaw);
    }
    final tamRaw = p.getString(_kTamanhosLegado);
    if (tamRaw != null && tamRaw.isNotEmpty && !await _fTamanhos.exists()) {
      await _gravarAtomico(_fTamanhos, tamRaw);
    }
    // Tira os pesos do SharedPreferences (a causa dos XML de MB).
    await p.remove(_kEnviadosLegado);
    await p.remove(_kJobLegado);
    await p.remove(_kTamanhosLegado);
    await p.setBool(_kMigrouArquivos, true);
  }

  Future<void> _carregarEnviados() async {
    _enviados.clear();
    final f = _fEnviados;
    if (!await f.exists()) return;
    try {
      // Parse de dezenas de milhares de linhas fora da thread da tela.
      final (mapa, linhas) = await compute(_parseEnviados, f.path);
      mapa.forEach((id, v) {
        _enviados[id] = EnvioInfo(fileId: v[0] as String?, bytes: v[1] as int?);
      });
      // Muitas linhas repetidas (atualizações de fileId, regravações)?
      // Compacta uma vez: boot seguinte lê menos.
      if (linhas > _enviados.length * 1.3 + 200) {
        await _compactarEnviados();
      }
    } catch (_) {}
  }

  Future<void> _carregarJob() async {
    _job = [];
    if (_dir == null) return;
    try {
      final f = _fJob;
      if (!await f.exists()) return;
      _job = await compute(_parseJob, f.path);
    } catch (_) {
      _job = [];
    }
  }

  Future<void> _carregarLegado() async {
    final p = await SharedPreferences.getInstance();
    for (final id in p.getStringList(_kEnviadosLegado) ?? const <String>[]) {
      _enviados[id] = const EnvioInfo();
    }
  }

  static Future<void> _gravarAtomico(File f, String conteudo) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(conteudo, flush: true);
    await tmp.rename(f.path);
  }

  /// Enfileira uma escrita atômica: nunca duas ao mesmo tempo no mesmo .tmp.
  Future<void> _naFilaAtomica(Future<void> Function() fn) {
    final f = _filaAtomica.then((_) => fn()).catchError((_) {});
    _filaAtomica = f;
    return f;
  }

  static String _linha(String id, EnvioInfo info) {
    final m = <String, Object>{'id': id};
    if (info.fileId != null) m['fileId'] = info.fileId!;
    if (info.bytes != null) m['bytes'] = info.bytes!;
    return jsonEncode(m);
  }

  Future<void> _compactarEnviados() async {
    if (_dir == null) return;
    await gravarAgora(); // appends pendentes antes de reescrever
    final copia = Map<String, EnvioInfo>.of(_enviados);
    final f = _fEnviados;
    await _naFilaAtomica(() async {
      final buf = StringBuffer();
      copia.forEach((id, info) => buf.writeln(_linha(id, info)));
      await _gravarAtomico(f, buf.toString());
    });
  }

  // ---------- Enviados ----------

  /// Cópia dos ids enviados (o main guarda a dele).
  Future<Set<String>> enviados() async => _enviados.keys.toSet();

  int get totalEnviados => _enviados.length;

  EnvioInfo? envioDe(String id) => _enviados[id];

  /// Aplica um envio em memória e devolve a linha a gravar (ou null se não
  /// mudou nada).
  String? _aplicar(String id, String? fileId, int? bytes) {
    final atual = _enviados[id];
    if (atual != null &&
        (fileId == null || atual.fileId == fileId) &&
        (bytes == null || atual.bytes == bytes)) {
      return null; // nada novo pra gravar
    }
    final info = EnvioInfo(
      fileId: fileId ?? atual?.fileId,
      bytes: bytes ?? atual?.bytes,
    );
    _enviados[id] = info;
    return _linha(id, info);
  }

  void _append(String texto) {
    if (_dir == null || texto.isEmpty) return;
    final f = _fEnviados;
    _filaEscrita = _filaEscrita.then((_) async {
      try {
        await f.writeAsString(texto, mode: FileMode.append, flush: true);
      } catch (_) {}
    });
  }

  /// Marca como enviado e grava NA HORA (uma linha em append; barato).
  /// Se já estava marcado e chega um fileId/tamanho novo, atualiza.
  Future<void> marcarEnviado(String id, {String? fileId, int? bytes}) async {
    final linha = _aplicar(id, fileId, bytes);
    if (linha != null) _append('$linha\n');
  }

  /// Marca vários de uma vez: UM append com todas as linhas.
  Future<void> marcarEnviadosEmLote(Iterable<NovoEnvio> envios) async {
    final buf = StringBuffer();
    for (final e in envios) {
      final linha = _aplicar(e.id, e.fileId, e.bytes);
      if (linha != null) buf.writeln(linha);
    }
    if (buf.isNotEmpty) _append(buf.toString());
  }

  /// Espera as filas de escrita esvaziarem. Chamar ao ir pro fundo/fechar.
  Future<void> gravarAgora() async {
    try {
      await _filaEscrita;
    } catch (_) {}
    try {
      await _filaAtomica;
    } catch (_) {}
  }

  /// Esquece ids (apagados do celular) e compacta o arquivo: reescreve uma vez,
  /// atômico. Acontece só no fluxo de apagar, que é raro.
  Future<void> esquecerEnviados(Iterable<String> ids) async {
    for (final id in ids) {
      _enviados.remove(id);
    }
    await _compactarEnviados();
  }

  // ---------- Job ----------

  /// O backup que o usuário pediu: lista de {id, titulo, pasta, bytes, path, dup}.
  Future<void> salvarJob(List<Map<String, String>> itens) async {
    _job = List.of(itens);
    if (_dir == null) return;
    final f = _fJob;
    final copia = List<Map<String, String>>.of(itens);
    await _naFilaAtomica(() async {
      final txt = await compute(_encodeJob, copia);
      await _gravarAtomico(f, txt);
    });
  }

  /// Cópia do job atual (em memória; lido do disco uma vez no boot).
  Future<List<Map<String, String>>> job() async =>
      List<Map<String, String>>.of(_job ?? const []);

  /// Tira ids do job (apagados do celular, ou que sumiram da galeria). Sem
  /// isso o job guardava ids que não existem mais, e a retomada tentava
  /// subir arquivos apagados pra sempre.
  Future<int> removerDoJob(Set<String> ids) async {
    final atual = _job;
    if (atual == null || atual.isEmpty || ids.isEmpty) return 0;
    final antes = atual.length;
    final novo = atual.where((m) => !ids.contains(m['id'])).toList();
    final removidos = antes - novo.length;
    if (removidos == 0) return 0;
    if (novo.isEmpty) {
      await limparJob();
    } else {
      await salvarJob(novo);
    }
    return removidos;
  }

  Future<void> limparJob() async {
    _job = [];
    if (_dir == null) return;
    final f = _fJob;
    await _naFilaAtomica(() async {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    });
  }

  // ---------- Cache de tamanhos (só fallbacks) ----------

  Future<Map<String, int>> tamanhos() async {
    if (_tamCache != null) return _tamCache!;
    _tamCache = {};
    if (_dir != null && await _fTamanhos.exists()) {
      try {
        final m = (jsonDecode(await _fTamanhos.readAsString()) as Map)
            .map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
        _tamCache = Map<String, int>.from(m);
      } catch (_) {}
    }
    return _tamCache!;
  }

  Future<void> salvarTamanhos(Map<String, int> novos) async {
    final cache = await tamanhos();
    cache.addAll(novos);
    if (_dir == null) return;
    final f = _fTamanhos;
    final txt = jsonEncode(cache);
    await _naFilaAtomica(() => _gravarAtomico(f, txt));
  }

  // ---------- Telemetria local (diagnóstico, nada sai do celular) ----------

  /// Grava o resumo de uma sessão de backup (uma linha em append): início,
  /// fim, quantos arquivos, GB, falhas e o último erro.
  Future<void> registrarSessao(Map<String, Object?> resumo) async {
    if (_dir == null) return;
    final linha = '${jsonEncode(resumo)}\n';
    final f = _fSessoes;
    _filaEscrita = _filaEscrita.then((_) async {
      try {
        await f.writeAsString(linha, mode: FileMode.append, flush: true);
      } catch (_) {}
    });
  }

  // ---------- Flags ----------

  Future<bool> pausado() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kPausado) ?? false;
  }

  Future<void> setPausado(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPausado, v);
  }

  /// Subir só no wifi. Padrão desligado: exigir wifi já travou backup em 0%
  /// quando o Android não classificava a rede (rodada 4). É escolha do usuário.
  Future<bool> soWifi() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kWifi) ?? false;
  }

  Future<void> setSoWifi(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kWifi, v);
  }

  /// Onboarding da primeira execução: mostrado uma vez só.
  static const _kViuOnboarding = 'viu_onboarding_v1';

  Future<bool> viuOnboarding() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kViuOnboarding) ?? false;
  }

  Future<void> marcarOnboardingVisto() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kViuOnboarding, true);
  }

  /// Migração única da rodada 5: limpa a fila herdada das builds antigas.
  Future<bool> precisaLimparFila() async {
    final p = await SharedPreferences.getInstance();
    return !(p.getBool(_kMigrouJanela) ?? false);
  }

  Future<void> marcarFilaLimpa() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kMigrouJanela, true);
  }
}

// ---------- Funções de isolate (top-level: só o argumento atravessa) ----------

(Map<String, List<Object?>>, int) _parseEnviados(String caminho) {
  final m = <String, List<Object?>>{};
  var n = 0;
  for (final l in File(caminho).readAsLinesSync()) {
    if (l.trim().isEmpty) continue;
    n++;
    try {
      final j = jsonDecode(l) as Map;
      final id = j['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final ant = m[id];
      // Linha mais nova vence, mas não apaga fileId/bytes já sabidos.
      m[id] = [
        j['fileId']?.toString() ?? ant?[0],
        (j['bytes'] as num?)?.toInt() ?? ant?[1],
      ];
    } catch (_) {
      // linha meio escrita num kill: ignora, o resto do arquivo vale
    }
  }
  return (m, n);
}

List<Map<String, String>> _parseJob(String caminho) {
  final raw = File(caminho).readAsStringSync();
  if (raw.isEmpty) return <Map<String, String>>[];
  final lista = (jsonDecode(raw) as List).cast<Map>();
  return lista
      .map((m) => m.map((k, v) => MapEntry(k.toString(), v.toString())))
      .toList();
}

String _encodeJob(List<Map<String, String>> itens) => jsonEncode(itens);
