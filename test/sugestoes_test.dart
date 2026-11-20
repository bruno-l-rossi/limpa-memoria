import 'package:flutter_test/flutter_test.dart';
import 'package:limpa_memoria/sugestoes.dart';

void main() {
  final hoje = DateTime(2026, 11, 20);
  test('WhatsApp pega Sent e Private pelo caminho inteiro', () {
    final g = montarSugestoes([
      MidiaSugestao('1', false, 10,
          'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent/', hoje),
      MidiaSugestao('2', false, 10, 'DCIM/Camera/', hoje),
    ], agora: hoje);
    final w = g.firstWhere((e) => e.titulo == 'Fotos do WhatsApp');
    expect(w.ids, ['1']);
  });

  test('vídeos do WhatsApp têm grupo próprio', () {
    final g = montarSugestoes([
      MidiaSugestao('v', true, 10,
          'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Sent/', hoje),
      MidiaSugestao('f', false, 10,
          'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/', hoje),
    ], agora: hoje);
    expect(g.firstWhere((e) => e.titulo == 'Vídeos do WhatsApp').ids, ['v']);
    expect(g.firstWhere((e) => e.titulo == 'Fotos do WhatsApp').ids, ['f']);
  });

  test('screenshots e downloads', () {
    final g = montarSugestoes([
      MidiaSugestao('1', false, 10, 'Pictures/Screenshots/', hoje),
      MidiaSugestao('2', false, 10, 'DCIM/Capturas de tela/', hoje),
      MidiaSugestao('3', false, 10, 'Download/', hoje),
    ], agora: hoje);
    expect(g.firstWhere((e) => e.titulo == 'Screenshots').ids, ['1', '2']);
    expect(g.firstWhere((e) => e.titulo == 'Downloads').ids, ['3']);
  });

  test('vídeo grande e mais antigo que 1 ano', () {
    final g = montarSugestoes([
      MidiaSugestao('1', true, 200 * 1024 * 1024, 'DCIM/', hoje),
      MidiaSugestao('2', false, 1, 'DCIM/', DateTime(2024, 1, 1)),
    ], agora: hoje);
    expect(g.firstWhere((e) => e.titulo == 'Vídeos grandes').ids, ['1']);
    expect(g.firstWhere((e) => e.titulo == 'Mais antigos que 1 ano').ids, ['2']);
  });

  test('grupo vazio não aparece', () {
    expect(montarSugestoes([], agora: hoje), isEmpty);
  });
}
