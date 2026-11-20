import 'formatos.dart';

/// Números da sessão de backup por faixa de tamanho (rodada 12). Servem pra
/// decidir otimizações com dado, não com chute: onde o tempo vai, em fotos
/// pequenas (custo por arquivo) ou em vídeos (banda). Nada sai do celular.
class Telemetria {
  static const faixas = ['<8 MB', '8–256 MB', '>256 MB'];
  static const _limites = [8 * 1024 * 1024, 256 * 1024 * 1024];

  DateTime inicio = DateTime.now();
  final List<int> arquivos = [0, 0, 0];
  final List<int> bytes = [0, 0, 0];
  int _preparos = 0;
  int _preparoMsTotal = 0;
  int retentativasRede = 0;
  int falhasDefinitivas = 0;

  void zerar() {
    inicio = DateTime.now();
    for (var i = 0; i < 3; i++) {
      arquivos[i] = 0;
      bytes[i] = 0;
    }
    _preparos = 0;
    _preparoMsTotal = 0;
    retentativasRede = 0;
    falhasDefinitivas = 0;
  }

  static int faixaDe(int b) =>
      b < _limites[0] ? 0 : (b < _limites[1] ? 1 : 2);

  void registrar(int b) {
    final f = faixaDe(b);
    arquivos[f]++;
    bytes[f] += b;
  }

  /// Tempo pra preparar um arquivo (subpasta + sessão no Drive + entregar ao
  /// Android). É o custo fixo que pesa nas fotos pequenas.
  void preparo(Duration d) {
    _preparos++;
    _preparoMsTotal += d.inMilliseconds;
  }

  int get preparoMedioMs => _preparos == 0 ? 0 : _preparoMsTotal ~/ _preparos;

  Map<String, Object> resumo() => {
        'porFaixa': {
          for (var i = 0; i < 3; i++)
            faixas[i]: {'arquivos': arquivos[i], 'bytes': bytes[i]}
        },
        'preparoMedioMs': preparoMedioMs,
        'retentativasRede': retentativasRede,
        'falhasDefinitivas': falhasDefinitivas,
      };

  /// Texto pro Diagnóstico.
  String texto() {
    final seg = DateTime.now().difference(inicio).inSeconds;
    final linhas = <String>[];
    for (var i = 0; i < 3; i++) {
      final mbps = seg > 0 ? bytes[i] / seg : 0;
      linhas.add(
          '${faixas[i]}: ${milhar(arquivos[i])} arquivos, ${fmtBytes(bytes[i])}'
          '${seg > 0 ? ' · ${fmtBytes(mbps.round())}/s · ${(arquivos[i] * 60 / seg).toStringAsFixed(1)} arq/min' : ''}');
    }
    linhas.add('Preparo médio por arquivo: $preparoMedioMs ms · '
        'quedas de rede: $retentativasRede · falhas: $falhasDefinitivas');
    return linhas.join('\n');
  }
}
