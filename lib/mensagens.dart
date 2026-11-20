/// Textos pro usuário (rodada 13). Erro técnico vai pro Diagnóstico; a tela
/// mostra o que aconteceu e o que fazer, em português claro.
library;

/// Traduz um erro bruto (exceção, HTTP, mensagem interna) num texto curto.
String mensagemAmigavel(Object? erro) {
  final t = '${erro ?? ''}';
  final b = t.toLowerCase();
  if (b.isEmpty) return 'Algo deu errado. Tente de novo.';
  if (b.contains('drive-cheio') ||
      b.contains('storagequotaexceeded') ||
      b.contains('encheu')) {
    return 'O Drive está cheio. Libere espaço na conta (ou assine mais) e toque em Retomar.';
  }
  if (b.contains('failed host lookup') ||
      b.contains('socketexception') ||
      b.contains('network is unreachable') ||
      b.contains('connection') ||
      b.contains('timed out') ||
      b.contains('timeout') ||
      b.contains('sem conexão') ||
      RegExp(r'\brede\b').hasMatch(b)) {
    return 'Sem conexão com a internet agora. Confira o wifi ou os dados e tente de novo.';
  }
  if (b.contains('sign_in_canceled') || b.contains('canceled')) {
    return 'Login cancelado.';
  }
  if (b.contains('network_error') || b.contains('apiexception: 7')) {
    return 'Sem conexão com o Google agora. Tente de novo em instantes.';
  }
  if (b.contains('apiexception: 10') || b.contains('developer_error')) {
    return 'O login com o Google não está configurado pra esta versão do app.';
  }
  if (b.contains('não está conectado') ||
      b.contains('entre de novo') ||
      b.contains('401') ||
      b.contains('token')) {
    return 'Sua conexão com o Google expirou. Entre de novo pelo ícone da conta.';
  }
  if (b.contains('429') || b.contains('ratelimit') || b.contains('rate limit')) {
    return 'O Google pediu uma pausa. O app continua sozinho em alguns minutos.';
  }
  if (b.contains('http 5') || b.contains('500') || b.contains('503')) {
    return 'O Google Drive está instável agora. O app tenta de novo sozinho.';
  }
  if (b.contains('chegou diferente')) {
    return 'Um arquivo chegou diferente no Drive. O app refaz o envio sozinho.';
  }
  if (b.contains('não consegui abrir') || b.contains('sumiu')) {
    return 'Um arquivo não pôde ser aberto no celular (foi apagado ou movido?).';
  }
  return 'Algo deu errado. Os detalhes estão em Ajustes > Diagnóstico.';
}
