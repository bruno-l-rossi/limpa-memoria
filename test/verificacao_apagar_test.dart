import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/modelos.dart';
import 'package:limpa_memoria/verificacao_apagar.dart';

const teto = 256 * 1024 * 1024;

CandidatoApagar c(String id,
        {String? fileId,
        int bytes = 100,
        bool v = false,
        String? md5,
        String titulo = 'IMG.jpg',
        String pasta = 'Camera'}) =>
    CandidatoApagar(
        id: id,
        titulo: titulo,
        pasta: pasta,
        bytesAgora: bytes,
        fileId: fileId,
        bytesEnviados: fileId != null ? bytes : null,
        verificado: v,
        md5Local: md5);

ArquivoDrive d(String fid, {int bytes = 100, String? md5 = 'aaa'}) =>
    ArquivoDrive(fid, 'IMG.jpg', bytes, 'Camera', md5: md5);

void main() {
  test('verificado no upload + fileId e tamanho batem: pode', () {
    final r = decidirApagar([c('1', fileId: 'f1', v: true)], [d('f1')], tetoMd5: teto);
    expect(r.pode, ['1']);
  });

  test('fileId sumiu do Drive: fica (naoAchado)', () {
    final r = decidirApagar([c('1', fileId: 'f1', v: true)], [d('f2')], tetoMd5: teto);
    expect(r.fica['1'], MotivoFica.naoAchado);
  });

  test('tamanho diferente: fica', () {
    final r = decidirApagar(
        [c('1', fileId: 'f1', v: true)], [d('f1', bytes: 99)], tetoMd5: teto);
    expect(r.fica['1'], MotivoFica.tamanho);
  });

  test('não verificado: precisa de MD5 igual', () {
    expect(decidirApagar([c('1', fileId: 'f1')], [d('f1')], tetoMd5: teto).fica['1'],
        MotivoFica.semMd5);
    expect(
        decidirApagar([c('1', fileId: 'f1', md5: 'bbb')], [d('f1')], tetoMd5: teto)
            .fica['1'],
        MotivoFica.md5Diferente);
    expect(
        decidirApagar([c('1', fileId: 'f1', md5: 'AAA')], [d('f1')], tetoMd5: teto).pode,
        ['1']);
  });

  test('o caso que perdia arquivo: duplicata falsa com o fileId do outro', () {
    // Dois arquivos diferentes, mesmo nome e tamanho. O 2 foi marcado (versão
    // antiga) com o fileId do 1. O MD5 do 2 não bate com o do Drive: fica.
    final r = decidirApagar([
      c('1', fileId: 'f1', md5: 'aaa'),
      c('2', fileId: 'f1', md5: 'zzz'),
    ], [d('f1')], tetoMd5: teto);
    expect(r.pode, ['1']);
    expect(r.fica['2'], MotivoFica.md5Diferente);
  });

  test('acima do teto vale o tamanho', () {
    final grande = 300 * 1024 * 1024;
    final r = decidirApagar([c('1', fileId: 'f1', bytes: grande)],
        [d('f1', bytes: grande, md5: null)], tetoMd5: teto);
    expect(r.pode, ['1']);
  });

  test('sem fileId: cada arquivo do Drive cobre só um do celular', () {
    final r = decidirApagar([
      c('1', md5: 'aaa'),
      c('2', md5: 'aaa'),
    ], [d('f1')], tetoMd5: teto);
    expect(r.pode, ['1']);
    expect(r.fica['2'], MotivoFica.naoAchado);
  });

  test('sem fileId: acha na pasta de nome antigo (antes da rodada 18)', () {
    final r = decidirApagar([
      c('1', md5: 'aaa', pasta: 'WhatsApp Images › Sent'),
    ], [
      ArquivoDrive('f1', 'IMG.jpg', 100, 'Sent', md5: 'aaa'),
    ], tetoMd5: teto);
    expect(r.pode, ['1']);
  });
}
