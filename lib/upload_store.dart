import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Guarda no próprio celular o que já subiu pro Drive e qual backup está em
/// andamento. É isso que faz o app continuar de onde parou em vez de recomeçar
/// do zero quando é fechado, perde sinal ou o celular reinicia.
class UploadStore {
  static const _kEnviados = 'ids_enviados';
  static const _kJob = 'job_pendente';

  /// Ids dos arquivos (asset.id) que já foram confirmados no Drive.
  Future<Set<String>> enviados() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_kEnviados) ?? const <String>[]).toSet();
  }

  Future<void> marcarEnviado(String id) async {
    final p = await SharedPreferences.getInstance();
    final lista = p.getStringList(_kEnviados) ?? <String>[];
    if (!lista.contains(id)) {
      lista.add(id);
      await p.setStringList(_kEnviados, lista);
    }
  }

  /// Tira ids da lista de enviados (usado depois de apagar do celular).
  Future<void> esquecerEnviados(Iterable<String> ids) async {
    final p = await SharedPreferences.getInstance();
    final alvo = ids.toSet();
    final lista = p.getStringList(_kEnviados) ?? <String>[];
    lista.removeWhere(alvo.contains);
    await p.setStringList(_kEnviados, lista);
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
}
