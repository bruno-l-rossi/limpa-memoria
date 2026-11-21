import 'dart:math';
import 'package:flutter/services.dart';

/// Info de uma mídia vinda direto do MediaStore.
class MidiaNativa {
  final int bytes;
  final String caminho; // caminho real no disco; vazio se o Android não deu
  const MidiaNativa(this.bytes, this.caminho);
}

/// Uma mídia da galeria vinda inteira do MediaStore (rodada 19, A-15).
/// Os mesmos campos que o photo_manager monta, sem paginar pelo plugin.
class MidiaGaleria {
  final String id;
  final int tipo; // 1 foto, 2 vídeo (mesmo número do AssetEntity.typeInt)
  final int bytes;
  final String caminho;
  final String nome;
  final int dataSeg; // data da foto (seg), mesma regra do photo_manager
  final int modSeg;
  final int duracaoSeg;
  final int largura, altura, orientacao;
  final String? caminhoRel; // null abaixo do Android 10 (como no photo_manager)
  final String mime;
  const MidiaGaleria({
    required this.id,
    required this.tipo,
    required this.bytes,
    required this.caminho,
    required this.nome,
    required this.dataSeg,
    required this.modSeg,
    required this.duracaoSeg,
    required this.largura,
    required this.altura,
    required this.orientacao,
    required this.caminhoRel,
    required this.mime,
  });
}

/// Monta as mídias a partir dos arrays paralelos do canal "galeria". Puro
/// (testado em test/galeria_nativa_test.dart). null = formato inesperado.
List<MidiaGaleria>? montarGaleria(Map<Object?, Object?> b) {
  final ids = b['ids'], sizes = b['sizes'], paths = b['paths'];
  final nomes = b['nomes'], tipos = b['tipos'], datas = b['datas'];
  final mods = b['mods'], durs = b['durs'], largs = b['largs'];
  final alts = b['alts'], oris = b['oris'], rels = b['rels'];
  final mimes = b['mimes'];
  final listas = [
    ids, sizes, paths, nomes, tipos, datas, mods, durs, largs, alts, oris,
    rels, mimes
  ];
  if (listas.any((l) => l is! List)) return null;
  final n = (ids as List).length;
  if (listas.any((l) => (l as List).length != n)) return null;
  final q = b['q'] == true;
  int i0(Object? v) => (v as num?)?.toInt() ?? 0;
  return [
    for (var i = 0; i < n; i++)
      MidiaGaleria(
        id: '${ids[i]}',
        tipo: i0((tipos as List)[i]) == 2 ? 2 : 1,
        bytes: i0((sizes as List)[i]),
        caminho: ((paths as List)[i] as String?) ?? '',
        nome: ((nomes as List)[i] as String?) ?? '',
        dataSeg: i0((datas as List)[i]),
        modSeg: i0((mods as List)[i]),
        duracaoSeg: i0((durs as List)[i]),
        largura: i0((largs as List)[i]),
        altura: i0((alts as List)[i]),
        orientacao: i0((oris as List)[i]),
        caminhoRel: q ? (((rels as List)[i] as String?) ?? '') : null,
        mime: ((mimes as List)[i] as String?) ?? '',
      )
  ];
}

/// Ponte pro canal nativo (MainActivity.kt). Tudo aqui tem fallback no Dart:
/// se o canal falhar (iOS, erro no aparelho), o app segue pelo caminho antigo.
class Nativo {
  static const _canal = MethodChannel('limpa_memoria/nativo');

  /// Tamanho e caminho de todas as mídias numa consulta só ao MediaStore.
  /// Devolve mapa vazio se o canal não responder (aí vale o fallback por arquivo).
  ///
  /// Rodada 10: a consulta roda numa thread nativa e volta em 3 arrays
  /// paralelos (ids, tamanhos, caminhos). Ainda aceita o formato antigo
  /// (mapa id -> [tamanho, caminho]) por segurança.
  static Future<Map<String, MidiaNativa>> midias() async {
    try {
      final bruto = await _canal
          .invokeMethod<Map<Object?, Object?>>('midias')
          .timeout(const Duration(seconds: 60));
      if (bruto == null) return {};
      final mapa = <String, MidiaNativa>{};
      final ids = bruto['ids'];
      final sizes = bruto['sizes'];
      final paths = bruto['paths'];
      if (ids is List && sizes is List && paths is List) {
        final n = min(ids.length, min(sizes.length, paths.length));
        for (var i = 0; i < n; i++) {
          final id = ids[i];
          if (id == null) continue;
          mapa['$id'] = MidiaNativa(
            (sizes[i] as num?)?.toInt() ?? 0,
            (paths[i] as String?) ?? '',
          );
        }
        return mapa;
      }
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

  /// Galeria inteira numa consulta só (rodada 19, A-15). null = não deu (aí o
  /// app pagina pelo photo_manager, como antes).
  static Future<List<MidiaGaleria>?> galeria() async {
    try {
      final b = await _canal
          .invokeMethod<Map<Object?, Object?>>('galeria')
          .timeout(const Duration(seconds: 60));
      return b == null ? null : montarGaleria(b);
    } catch (_) {
      return null;
    }
  }

  // --- Motor nativo (rodada 19, F4) ---

  /// Autoriza o Drive pro motor nativo. Pode abrir a tela de confirmação do
  /// Google (só com o app aberto). true = autorizado.
  static Future<bool> motorAutorizar(String email) async {
    try {
      return await _canal.invokeMethod<bool>(
              'motorAutorizar', {'email': email}).timeout(
              const Duration(minutes: 5),
              onTimeout: () => false) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Liga o motor nativo (lê a fila de fila.json). true = agendou ou já rodava.
  static Future<bool> motorIniciar(
      {required String email, required bool soWifi, required int bytes}) async {
    try {
      return await _canal.invokeMethod<bool>('motorIniciar',
              {'email': email, 'soWifi': soWifi, 'bytes': bytes}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> motorParar() async {
    try {
      await _canal.invokeMethod('motorParar');
    } catch (_) {}
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
      return await _canal
          .invokeMethod<String>('md5', {'path': path}).timeout(
              const Duration(minutes: 5),
              onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  /// O app tem a permissão de ler a LOCALIZAÇÃO das mídias? Sem ela o
  /// Android entrega as fotos sem o GPS do EXIF. Em erro devolve true pra não
  /// travar aparelhos sem o canal (o Android antigo nem tem essa permissão).
  static Future<bool> localizacaoMidiaPermitida() async {
    try {
      return await _canal.invokeMethod<bool>('localizacaoMidia') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Share sheet do Android com um texto.
  /// Versão do Android (API). 0 se não deu pra saber.
  static Future<int> sdk() async {
    try {
      return await _canal.invokeMethod<int>('sdk') ?? 0;
    } catch (_) {
      return 0;
    }
  }

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
