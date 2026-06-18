import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Guarda no próprio celular o que já subiu pro Drive e qual backup está em
/// andamento. É isso que faz o app continuar de onde parou em vez de recomeçar
/// do zero quando é fechado, perde sinal ou o celular reinicia.
///
/// A lista de enviados fica na memória como fonte da verdade e é gravada em
/// lote (não a cada arquivo). Isso evita gravações se atropelando quando vários
/// uploads terminam juntos, que era o que fazia o contador "voltar pro zero".
class UploadStore {
  static const _kEnviados = 'ids_enviados';
  static const _kJob = 'job_pendente';

  Set<String>? _cache;
  Timer? _timer;

  Future<Set<String>> enviados() async {
    if (_cache != null) return _cache!;
    final p = await SharedPreferences.getInstance();
    _cache = (p.getStringList(_kEnviados) ?? const <String>[]).toSet();
    return _cache!;
  }

  Future<void> marcarEnviado(String id) async {
    final set = await enviados();
    if (set.add(id)) _agendarGravacao();
  }

  void _agendarGravacao() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), gravarAgora);
  }

  /// Grava a lista atual no disco. Chamada em lote e quando o app vai pro fundo.
  Future<void> gravarAgora() async {
    _timer?.cancel();
    if (_cache == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kEnviados, _cache!.toList());
  }

  Future<void> esquecerEnviados(Iterable<String> ids) async {
    final set = await enviados();
    set.removeAll(ids.toSet());
    await gravarAgora();
  }

  /// O backup que o usuário pediu: lista de {id, titulo, pasta}. Serve pra saber
  /// o total e o que ainda falta ao reabrir o app.
  Future<void> salvarJob(List<Map<String, String>> itens) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kJob, jsonEncode(itens));
  }

  Future<List<Map<String, String>>> job() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kJob);
    if (raw == null || raw.isEmpty) return [];
    final lista = (jsonDecode(raw) as List).cast<Map>();
    return lista
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v.toString())))
        .toList();
  }

  Future<void> limparJob() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kJob);
  }

  /// Migração única: limpa a fila herdada das builds antigas só uma vez.
  static const _kMigrouJanela = 'migrou_janela_v1';

  Future<bool> precisaLimparFila() async {
    final p = await SharedPreferences.getInstance();
    return !(p.getBool(_kMigrouJanela) ?? false);
  }

  Future<void> marcarFilaLimpa() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kMigrouJanela, true);
  }
}
