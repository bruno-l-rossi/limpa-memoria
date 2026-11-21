import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/formatos.dart';

void main() {
  test('fmtBytes', () {
    expect(fmtBytes(0), '0 B');
    expect(fmtBytes(-5), '0 B');
    expect(fmtBytes(512), '512 B');
    expect(fmtBytes(1536), '1,5 KB');
    expect(fmtBytes(5 * 1024 * 1024 * 1024), '5,0 GB');
  });

  test('milhar', () {
    expect(milhar(0), '0');
    expect(milhar(999), '999');
    expect(milhar(19000), '19.000');
    expect(milhar(1234567), '1.234.567');
    expect(milhar(-4312), '-4.312');
  });

  test('textoEta', () {
    expect(textoEta(0), '');
    expect(textoEta(30), '~1 min restante');
    expect(textoEta(600), '~10 min restantes');
    expect(textoEta(3600 * 2 + 600), '~2h10 restantes');
    // 59,6 min arredondaria pra "1h60": vira 2h00
    expect(textoEta(3600 + 3590), '~2h00 restantes');
    expect(textoEta(3600 * 72), '~3 dias restantes');
  });

  test('estimarSegundos usa o maior gargalo', () {
    expect(estimarSegundos(bytesRestantes: 1000, bytesPorSeg: 0), 0);
    expect(estimarSegundos(bytesRestantes: 1000, bytesPorSeg: 10), 100);
    expect(
        estimarSegundos(
            bytesRestantes: 1000,
            bytesPorSeg: 10,
            pequenosRestantes: 500,
            pequenosPorSeg: 1),
        500);
  });
}
