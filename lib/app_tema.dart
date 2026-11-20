part of 'main.dart';

// Rodada 18: saiu do main.dart (achado A-32).

// Cores (rodada 18: modo escuro). Viraram getters que olham o tema em uso;
// o MaterialApp acerta _escuro antes de desenhar as telas (ver MyApp).
bool _escuro = false;
Color get _actionBlue =>
    _escuro ? const Color(0xFF5AA9FF) : const Color(0xFF0066CC);
Color get _ink => _escuro ? const Color(0xFFF2F2F7) : const Color(0xFF1D1D1F);
Color get _inkMuted =>
    _escuro ? const Color(0xFF9A9AA0) : const Color(0xFF7A7A7A);
Color get _canvas => _escuro ? const Color(0xFF111113) : const Color(0xFFFFFFFF);
Color get _parchment =>
    _escuro ? const Color(0xFF1E1E21) : const Color(0xFFF5F5F7);
Color get _hairline =>
    _escuro ? const Color(0xFF3A3A3D) : const Color(0xFFE0E0E0);
Color get _avisoFundo =>
    _escuro ? const Color(0xFF3B2C14) : const Color(0xFFFFF4E5);
Color get _erroTexto =>
    _escuro ? const Color(0xFFFF8A80) : const Color(0xFFB00020);
/// Chamar no build de quem usa as cores acima: assim a tela redesenha quando
/// o tema troca (o sistema passa pro escuro à noite, por exemplo).
void _dependerDoTema(BuildContext context) => Theme.of(context);
ThemeData _tema(Brightness brilho) {
  final antes = _escuro;
  _escuro = brilho == Brightness.dark; // as cores abaixo saem no tom certo
  final scheme = ColorScheme.fromSeed(
    seedColor: _actionBlue,
    primary: _actionBlue,
    brightness: brilho,
  );
  final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Inter',
      brightness: brilho);
  final tema = base.copyWith(
    scaffoldBackgroundColor: _canvas,
    textTheme: base.textTheme.apply(bodyColor: _ink, displayColor: _ink),
    appBarTheme: AppBarTheme(
      backgroundColor: _canvas,
      foregroundColor: _ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          color: _ink,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: _actionBlue,
        foregroundColor: _escuro ? Colors.black : Colors.white,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: const TextStyle(
            fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w400),
      ),
    ),
  );
  _escuro = antes; // quem decide o tom em uso é o MaterialApp.builder
  return tema;
}
/// Tema escolhido em Ajustes: 'sistema' (padrão), 'claro' ou 'escuro'.
final ValueNotifier<String> _temaApp = ValueNotifier('sistema');
