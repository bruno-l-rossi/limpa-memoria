import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/manutencao_drive.dart';
import 'package:limpa_memoria/modelos.dart';

ItemEnviado _e(String id, String nome, String pasta, int bytes,
        {String? fileId, int data = 0}) =>
    (
      item: ItemBackup(id, nome, pasta, bytes: bytes, data: data),
      fileId: fileId
    );

ArquivoDrive _a(String fid, String nome, String pasta, int bytes,
        {String? pai, DateTime? mod}) =>
    ArquivoDrive(fid, nome, bytes, pasta, paiId: pai ?? 'pai-$pasta', modificado: mod);

void main() {
  test('move da pasta antiga pra nova, pelo fileId', () {
    final plano = planejarMovimentos([
      _e('1', 'a.jpg', 'WhatsApp Images › Sent', 10, fileId: 'f1'),
    ], [
      _a('f1', 'a.jpg', 'Sent', 10, pai: 'sent-id'),
    ]);
    expect(plano.length, 1);
    expect(plano.first.fileId, 'f1');
    expect(plano.first.de, 'sent-id');
    expect(plano.first.paraPasta, 'WhatsApp Images › Sent');
  });

  test('sem fileId casa por nome e tamanho na pasta antiga', () {
    final plano = planejarMovimentos([
      _e('1', 'v.mp4', 'WhatsApp Video › Sent', 99),
    ], [
      _a('f9', 'v.mp4', 'Sent', 99),
    ]);
    expect(plano.single.fileId, 'f9');
  });

  test('já na pasta nova ou pasta que não mudou: nada a mover', () {
    expect(
        planejarMovimentos([
          _e('1', 'a.jpg', 'WhatsApp Images › Sent', 10, fileId: 'f1'),
          _e('2', 'b.jpg', 'Camera', 10, fileId: 'f2'),
        ], [
          _a('f1', 'a.jpg', 'WhatsApp Images › Sent', 10),
          _a('f2', 'b.jpg', 'Camera', 10),
        ]),
        isEmpty);
  });

  test('nunca move de uma pasta que não é a antiga dessa mesma pasta', () {
    // fileId aponta pra um arquivo em "Camera": não é a pasta antiga de
    // "WhatsApp Images › Sent" (que seria "Sent"), então fica onde está.
    expect(
        planejarMovimentos([
          _e('1', 'a.jpg', 'WhatsApp Images › Sent', 10, fileId: 'f1'),
        ], [
          _a('f1', 'a.jpg', 'Camera', 10),
        ]),
        isEmpty);
  });

  test('um arquivo do Drive cobre um item só (fileId reserva antes)', () {
    final casados = casarComDrive([
      _e('semFid', 'a.jpg', 'X › Sent', 10),
      _e('comFid', 'a.jpg', 'X › Sent', 10, fileId: 'f1'),
    ], [
      _a('f1', 'a.jpg', 'Sent', 10),
    ]);
    expect(casados.keys, ['comFid']);
  });

  final agora = DateTime.utc(2026, 11, 20);
  final dataFoto = DateTime.utc(2021, 5, 3, 10).millisecondsSinceEpoch;

  test('corrige data que ficou com a data do upload', () {
    final plano = planejarDatas([
      _e('1', 'a.jpg', 'Camera', 10, fileId: 'f1', data: dataFoto),
    ], [
      _a('f1', 'a.jpg', 'Camera', 10, mod: DateTime.utc(2026, 11, 1)),
    ], agora: agora);
    expect(plano.single.fileId, 'f1');
    expect(plano.single.data.millisecondsSinceEpoch, dataFoto);
  });

  test('data já certa, ou data da mídia inválida: não mexe', () {
    expect(
        planejarDatas([
          _e('1', 'a.jpg', 'Camera', 10, fileId: 'f1', data: dataFoto),
          _e('2', 'b.jpg', 'Camera', 10, fileId: 'f2', data: 0),
        ], [
          _a('f1', 'a.jpg', 'Camera', 10,
              mod: DateTime.fromMillisecondsSinceEpoch(dataFoto + 1500,
                  isUtc: true)),
          _a('f2', 'b.jpg', 'Camera', 10, mod: DateTime.utc(2026, 11, 1)),
        ], agora: agora),
        isEmpty);
  });

  test('dataValida', () {
    expect(dataValida(0, agora: agora), isFalse);
    expect(dataValida(DateTime.utc(1985).millisecondsSinceEpoch, agora: agora),
        isFalse);
    expect(dataValida(dataFoto, agora: agora), isTrue);
    expect(
        dataValida(DateTime.utc(2027).millisecondsSinceEpoch, agora: agora),
        isFalse);
  });
}
