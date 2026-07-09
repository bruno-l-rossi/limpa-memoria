import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// O que sabemos de um arquivo já enviado: o id do arquivo no Drive (pra
/// conferir antes de apagar do celular) e o tamanho em bytes.
class EnvioInfo {
  final String? fileId;
  final int? bytes;
  const EnvioInfo({this.fileId, this.bytes});
}

/// Persistência no celular do que já subiu e do backup em andamento.
///
/// Rodada 8: saiu do SharedPreferences (que reescreve um XML inteiro de vários
/// MB a cada gravação e não aguenta 20-30 mil ids) pra arquivos próprios na
/// pasta de dados do app:
///
/// - enviados.jsonl: UMA LINHA por arquivo enviado, em append. Gravar um envio
///   custa uma linha, não o arquivo inteiro. Sobrevive a kill no meio (a linha
///   ou entrou ou não entrou; nunca corrompe o resto).
/// - job.json: o backup pedido pelo usuário. Escrita atômica (tmp + rename).
/// - tamanhos.json: cache de tamanhos SÓ dos fallbacks (a fonte principal agora
///   é o MediaStore via canal nativo, numa consulta só).
///
/// Flags pequenas (pausado, wifi, migrações) continuam no SharedPreferences,
/// que é ótimo pra bool.
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
  // Fila de escrita: appends encadeados um após o outro, cada um com flush.
  // Sem buffer em memória = um kill não perde linha já "gravada".
  Future<void> _filaEscrita = Future.value();
  bool _pronto = false;

  File get _fEnviados => File('${_dir!.path}/enviados.jsonl');
  File get _fJob => File('${_dir!.path}/job.json');
  File get _fTamanhos => File('${_dir!.path}/tamanhos.json');

  /// Chamar UMA vez no boot, antes de qualquer leitura. Carrega os enviados
  /// pra memória e roda a migração do SharedPreferences se for a primeira vez.
  Future<void> init(String? dirDados) async {
    if (_pronto) return;
    if (dirDados == null || dirDados.isEmpty) {
      // Sem canal nativo (não deveria acontecer no Android). Segue só com o
      // legado do SharedPreferences pra não perder o histórico.
      await _carregarLegado();
      _pronto = true;
      return;
    }
    _dir = Directory(dirDados);
    await _migrarSePrecisar();
    await _carregarEnviados();
    _pronto = true;
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
    if (!await _fEnviados.exists()) return;
    try {
      final linhas = await _fEnviados.readAsLines();
      for (final l in linhas) {
        if (l.trim().isEmpty) continue;
        try {
          final m = jsonDecode(l) as Map;
          final id = m['id']?.toString();
          if (id == null || id.isEmpty) continue;
          _enviados[id] = EnvioInfo(
            fileId: m['fileId']?.toString(),
            bytes: (m['bytes'] as num?)?.toInt(),
          );
        } catch (_) {
          // linha meio escrita num kill: ignora, o resto do arquivo vale
        }
      }
    } catch (_) {}
  }

  Future<void> _carregarLegado() async {
    final p = await SharedPreferences.getInstance();
    for (final id in p.getStringList(_kEnviadosLegado) ?? const <String>[]) {
      _enviados[id] = const EnvioInfo();
    }
  }

  Future<void> _gravarAtomico(File f, String conteudo) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(conteudo, flush: true);
    await tmp.rename(f.path);
  }

  // ---------- Enviados ----------

  Future<Set<String>> enviados() async => _enviados.keys.toSet();

  EnvioInfo? envioDe(String id) => _enviados[id];

  /// Marca como enviado e grava NA HORA (uma linha em append; barato).
  Future<void> marcarEnviado(String id, {String? fileId, int? bytes}) async {
    final atual = _enviados[id];
    if (atual != null &&
        (fileId == null || atual.fileId == fileId) &&
        (bytes == null || atual.bytes == bytes)) {
      return; // nada novo pra gravar
    }
    _enviados[id] = EnvioInfo(
      fileId: fileId ?? atual?.fileId,
      bytes: bytes ?? atual?.bytes,
    );
    if (_dir == null) return;
    final m = <String, Object>{'id': id};
    final info = _enviados[id]!;
    if (info.fileId != null) m['fileId'] = info.fileId!;
    if (info.bytes != null) m['bytes'] = info.bytes!;
    final linha = '${jsonEncode(m)}\n';
    // Encadeia na fila: uma escrita por vez, com flush, sem se atropelar.
    _filaEscrita = _filaEscrita.then((_) async {
      try {
        await _fEnviados.writeAsString(linha,
            mode: FileMode.append, flush: true);
      } catch (_) {}
    });
  }

  /// Espera a fila de escrita esvaziar. Chamar ao ir pro fundo/fechar.
  Future<void> gravarAgora() async {
    try {
      await _filaEscrita;
    } catch (_) {}
  }

  /// Esquece ids (apagados do celular) e compacta o arquivo: reescreve uma vez,
  /// atômico. Acontece só no fluxo de apagar, que é raro.
  Future<void> esquecerEnviados(Iterable<String> ids) async {
    for (final id in ids) {
      _enviados.remove(id);
    }
    if (_dir == null) return;
    await gravarAgora(); // espera os appends pendentes antes de compactar
    final buf = StringBuffer();
    _enviados.forEach((id, info) {
      final m = <String, Object>{'id': id};
      if (info.fileId != null) m['fileId'] = info.fileId!;
      if (info.bytes != null) m['bytes'] = info.bytes!;
      buf.writeln(jsonEncode(m));
    });
    await _gravarAtomico(_fEnviados, buf.toString());
  }

  // ---------- Job ----------

  /// O backup que o usuário pediu: lista de {id, titulo, pasta, bytes, path}.
  Future<void> salvarJob(List<Map<String, String>> itens) async {
    if (_dir == null) return;
    await _gravarAtomico(_fJob, jsonEncode(itens));
  }

  Future<List<Map<String, String>>> job() async {
    if (_dir == null || !await _fJob.exists()) return [];
    try {
      final raw = await _fJob.readAsString();
      if (raw.isEmpty) return [];
      final lista = (jsonDecode(raw) as List).cast<Map>();
      return lista
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v.toString())))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> limparJob() async {
    try {
      if (_dir != null && await _fJob.exists()) await _fJob.delete();
    } catch (_) {}
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
    await _gravarAtomico(_fTamanhos, jsonEncode(cache));
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
