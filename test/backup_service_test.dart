import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/backup_service.dart';

void main() {
  test('metadados levam a data da mídia', () {
    final ms = DateTime.utc(2021, 5, 3, 10).millisecondsSinceEpoch;
    final m = BackupService.metadadosUpload('a.jpg', 'pasta', ms);
    expect(m['name'], 'a.jpg');
    expect(m['parents'], ['pasta']);
    expect(m['modifiedTime'], '2021-05-03T10:00:00.000Z');
    expect(m['createdTime'], '2021-05-03T10:00:00.000Z');
  });

  test('data absurda fica de fora', () {
    expect(BackupService.metadadosUpload('a', 'p', 0).containsKey('modifiedTime'),
        isFalse);
    final futuro =
        DateTime.now().add(const Duration(days: 400)).millisecondsSinceEpoch;
    expect(
        BackupService.metadadosUpload('a', 'p', futuro)
            .containsKey('modifiedTime'),
        isFalse);
  });

  test('classificação de erro', () {
    expect(BackupService.ehTransitorio(const SocketException('x')), isTrue);
    expect(BackupService.ehTransitorio(TimeoutException('x')), isTrue);
    expect(BackupService.ehTransitorio(Exception('Failed host lookup: www')),
        isTrue);
    expect(BackupService.ehTransitorio(Exception('arquivo inválido')), isFalse);
  });

  test('resposta do upload', () {
    expect(BackupService.extrairArquivoDaResposta(
            '{"id":"f","size":"12","md5Checksum":"ab"}'),
        ('f', 12, 'ab'));
    expect(BackupService.extrairArquivoDaResposta(null), (null, null, null));
    expect(BackupService.extrairArquivoDaResposta('lixo'), (null, null, null));
  });
}
