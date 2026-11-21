import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/nativo.dart';

Map<Object?, Object?> _bruto({bool q = true, int n = 2}) => {
      'ids': [11, 12].take(n).toList(),
      'sizes': [100, 2000].take(n).toList(),
      'paths': ['/sd/DCIM/a.jpg', '/sd/WhatsApp/v.mp4'].take(n).toList(),
      'nomes': ['a.jpg', 'v.mp4'].take(n).toList(),
      'tipos': [1, 2].take(n).toList(),
      'datas': [1620000000, 1630000000].take(n).toList(),
      'mods': [1620000001, 1630000001].take(n).toList(),
      'durs': [0, 42].take(n).toList(),
      'largs': [4000, 1920].take(n).toList(),
      'alts': [3000, 1080].take(n).toList(),
      'oris': [90, 0].take(n).toList(),
      'rels': ['DCIM/Camera/', 'WhatsApp Video/Sent/'].take(n).toList(),
      'mimes': ['image/jpeg', 'video/mp4'].take(n).toList(),
      'q': q,
    };

void main() {
  test('monta as mídias dos arrays paralelos', () {
    final g = montarGaleria(_bruto())!;
    expect(g.length, 2);
    expect(g[0].id, '11');
    expect(g[0].tipo, 1);
    expect(g[0].orientacao, 90);
    expect(g[1].tipo, 2);
    expect(g[1].duracaoSeg, 42);
    expect(g[1].caminhoRel, 'WhatsApp Video/Sent/');
    expect(g[1].bytes, 2000);
  });

  test('abaixo do Android 10 não tem caminho relativo (igual photo_manager)',
      () {
    expect(montarGaleria(_bruto(q: false))!.first.caminhoRel, isNull);
  });

  test('arrays de tamanhos diferentes: recusa (cai no caminho antigo)', () {
    final b = _bruto()..['nomes'] = ['só um'];
    expect(montarGaleria(b), isNull);
    expect(montarGaleria({'ids': [1]}), isNull);
  });
}
