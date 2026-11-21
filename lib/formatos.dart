/// Formatação de números pra tela, em pt-BR. Funções puras (testadas em
/// test/formatos_test.dart).
library;

/// 1536 -> "1,5 KB". Zero ou negativo -> "0 B".
String fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  final txt = i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '${txt.replaceAll('.', ',')} ${u[i]}';
}

/// 19000 -> "19.000"
String milhar(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
    buf.write(s[i]);
  }
  return buf.toString();
}

/// Segundos restantes -> texto curto ("~12 min restantes"). <=0 -> "".
String textoEta(double segundos) {
  if (segundos <= 0 || segundos.isNaN || segundos.isInfinite) return '';
  final s = segundos.round();
  if (s < 90) return '~1 min restante';
  if (s < 3600) return '~${(s / 60).round()} min restantes';
  final h = s ~/ 3600;
  final m = ((s % 3600) / 60).round();
  if (h >= 48) return '~${(h / 24).round()} dias restantes';
  if (m == 60) return '~${h + 1}h00 restantes';
  return '~${h}h${m.toString().padLeft(2, '0')} restantes';
}

/// Estimativa em segundos: o maior entre "bytes / banda" e "arquivos pequenos
/// / arquivos por segundo" (no fim do backup manda o custo por arquivo).
double estimarSegundos({
  required int bytesRestantes,
  required double bytesPorSeg,
  int pequenosRestantes = 0,
  double pequenosPorSeg = 0,
}) {
  if (bytesPorSeg <= 0 || bytesRestantes <= 0) return 0;
  var segs = bytesRestantes / bytesPorSeg;
  if (pequenosPorSeg > 0 && pequenosRestantes > 0) {
    final porArquivo = pequenosRestantes / pequenosPorSeg;
    if (porArquivo > segs) segs = porArquivo;
  }
  return segs;
}
