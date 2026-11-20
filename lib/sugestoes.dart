/// Sugestões prontas de backup (rodada 13). Pura e testada.
///
/// Antes as regras olhavam só o último pedaço do caminho ("Sent" de
/// "WhatsApp Images/Sent" escapava do grupo WhatsApp). Agora olham o caminho
/// relativo inteiro.
library;

class MidiaSugestao {
  final String id;
  final bool video;
  final int bytes;
  final String caminho; // relativePath completo, ex.: "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent/"
  final DateTime data;
  const MidiaSugestao(this.id, this.video, this.bytes, this.caminho, this.data);
}

class GrupoSugestao {
  final String titulo;
  final String descricao;
  final List<String> ids;
  final int bytes;
  const GrupoSugestao(this.titulo, this.descricao, this.ids, this.bytes);
}

bool ehWhatsApp(String caminho) => caminho.toLowerCase().contains('whatsapp');

bool ehScreenshot(String caminho) {
  final c = caminho.toLowerCase();
  return c.contains('screenshot') ||
      c.contains('captura') ||
      c.contains('screen_record') ||
      c.contains('screenrecord');
}

bool ehDownload(String caminho) => caminho.toLowerCase().contains('download');

/// Monta os grupos a partir do que ainda NÃO está no Drive.
List<GrupoSugestao> montarSugestoes(List<MidiaSugestao> fora,
    {DateTime? agora, int videoGrande = 100 * 1024 * 1024}) {
  final hoje = agora ?? DateTime.now();
  final umAno = hoje.subtract(const Duration(days: 365));
  final grupos = <GrupoSugestao>[];
  void add(String t, String d, bool Function(MidiaSugestao) f) {
    final l = fora.where(f).toList();
    if (l.isEmpty) return;
    grupos.add(GrupoSugestao(
        t, d, [for (final m in l) m.id], l.fold(0, (s, m) => s + m.bytes)));
  }

  add('Vídeos grandes', 'Acima de 100 MB',
      (m) => m.video && m.bytes > videoGrande);
  // Rodada 18: vídeos do WhatsApp em grupo próprio (são o grosso do espaço).
  add('Vídeos do WhatsApp', 'Recebidos e enviados',
      (m) => m.video && ehWhatsApp(m.caminho));
  add('Fotos do WhatsApp', 'Recebidas e enviadas',
      (m) => !m.video && ehWhatsApp(m.caminho));
  add('Mais antigos que 1 ano', 'Você quase não abre',
      (m) => m.data.isBefore(umAno));
  add('Screenshots', 'Capturas e gravações de tela',
      (m) => ehScreenshot(m.caminho));
  add('Downloads', 'Baixados da internet', (m) => ehDownload(m.caminho));
  return grupos;
}
