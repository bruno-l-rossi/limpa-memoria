/// Ponte pro diário de eventos (eventos.log), pra quem não tem acesso ao
/// UploadStore (o BackupService é estático). Rodada 18, achado A-36: os
/// `catch (_) {}` do motor escondiam falha; agora deixam rastro no Diagnóstico.
library;

/// O main liga isto ao diário depois de abrir o store.
void Function(String texto)? registrarNoDiario;

/// Registra uma falha engolida de propósito (o fluxo segue), com o lugar.
void falhaEngolida(String onde, Object erro) {
  try {
    registrarNoDiario?.call('Falha ignorada em $onde: $erro');
  } catch (_) {
    // o diário nunca pode derrubar quem chamou
  }
}
