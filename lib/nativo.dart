import 'package:flutter/services.dart';

/// Info de uma mídia vinda direto do MediaStore.
class MidiaNativa {
  final int bytes;
  final String caminho; // caminho real no disco; vazio se o Android não deu
  const MidiaNativa(this.bytes, this.caminho);
}

/// Ponte pro canal nativo (MainActivity.kt). Tudo aqui tem fallback no Dart:
/// se o canal falhar (iOS, erro no aparelho), o app segue pelo caminho antigo.
class Nativo {
  static const _canal = MethodChannel('limpa_memoria/nativo');

  /// Tamanho e caminho de todas as mídias numa consulta só ao MediaStore.
  /// Devolve mapa vazio se o canal não responder (aí vale o fallback por arquivo).
  static Future<Map<String, MidiaNativa>> midias() async {
    try {
      final bruto = await _canal.invokeMethod<Map<Object?, Object?>>('midias');
      if (bruto == null) return {};
      final mapa = <String, MidiaNativa>{};
      bruto.forEach((k, v) {
        if (k is String && v is List && v.length >= 2) {
          final bytes = (v[0] as num?)?.toInt() ?? 0;
          final caminho = v[1] as String? ?? '';
          mapa[k] = MidiaNativa(bytes, caminho);
        }
      });
      return mapa;
    } catch (_) {
      return {};
    }
  }

  /// Pasta de dados do app (pro armazenamento em arquivo do upload_store).
  static Future<String?> dirDados() async {
    try {
      return await _canal.invokeMethod<String>('dirDados');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> bateriaIsenta() async {
    try {
      return await _canal.invokeMethod<bool>('bateriaIsenta') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Abre o diálogo do Android pedindo isenção de bateria. Devolve o estado
  /// no momento da resposta (o usuário pode decidir depois, no diálogo).
  static Future<bool> pedirIsencaoBateria() async {
    try {
      return await _canal.invokeMethod<bool>('pedirIsencaoBateria') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// MD5 de um arquivo (hex minúsculo), calculado em thread nativa.
  /// null = não conseguiu (aí o app segue sem a checagem, não bloqueia).
  static Future<String?> md5(String path) async {
    try {
      return await _canal.invokeMethod<String>('md5', {'path': path});
    } catch (_) {
      return null;
    }
  }

  /// Share sheet do Android com um texto.
  static Future<void> compartilhar(String texto) async {
    try {
      await _canal.invokeMethod('compartilhar', {'texto': texto});
    } catch (_) {}
  }

  /// Notificação de progresso com o número REAL da sessão.
  static Future<void> notificar(
      String titulo, String texto, int feitos, int total) async {
    try {
      await _canal.invokeMethod('notificar', {
        'titulo': titulo,
        'texto': texto,
        'feitos': feitos,
        'total': total,
      });
    } catch (_) {}
  }

  static Future<void> limparNotificacao() async {
    try {
      await _canal.invokeMethod('limparNotificacao');
    } catch (_) {}
  }
}
