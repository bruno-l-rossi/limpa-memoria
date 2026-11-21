import 'dart:collection';

/// Seleção da grade com as contas feitas na hora em que muda (rodada 18,
/// achado A-16). Antes, cada desenho da tela (2 por segundo durante o
/// backup) somava os bytes da seleção inteira e varria cada pasta pra saber
/// se estava marcada. Com 30 mil itens isso pesava.
/// Testes em test/selecao_test.dart.
class Selecao<T> extends SetBase<T> {
  final int Function(T) bytesDe;
  final String Function(T) grupoDe;
  Selecao({required this.bytesDe, required this.grupoDe});

  // Bytes guardados na hora em que entrou: tirar subtrai o mesmo valor, mesmo
  // que o tamanho do item mude depois (a leitura de tamanhos corrige devagar).
  final LinkedHashMap<T, int> _itens = LinkedHashMap();
  final Map<String, int> _porGrupo = {};
  int _bytes = 0;

  /// Soma dos bytes dos selecionados.
  int get bytes => _bytes;

  /// Quantos selecionados nesse grupo (pasta).
  int noGrupo(String grupo) => _porGrupo[grupo] ?? 0;

  /// Refaz as contas com os tamanhos de agora (depois de ler tamanhos).
  void recalcular() {
    _bytes = 0;
    for (final k in _itens.keys.toList()) {
      final b = bytesDe(k);
      _itens[k] = b;
      _bytes += b;
    }
  }

  @override
  bool add(T value) {
    if (_itens.containsKey(value)) return false;
    final b = bytesDe(value);
    _itens[value] = b;
    _bytes += b;
    final g = grupoDe(value);
    _porGrupo[g] = (_porGrupo[g] ?? 0) + 1;
    return true;
  }

  @override
  bool remove(Object? value) {
    if (!_itens.containsKey(value)) return false;
    final b = _itens.remove(value)!;
    _bytes -= b;
    final g = grupoDe(value as T);
    final n = (_porGrupo[g] ?? 1) - 1;
    if (n <= 0) {
      _porGrupo.remove(g);
    } else {
      _porGrupo[g] = n;
    }
    return true;
  }

  @override
  void clear() {
    _itens.clear();
    _porGrupo.clear();
    _bytes = 0;
  }

  @override
  bool contains(Object? element) => _itens.containsKey(element);

  @override
  T? lookup(Object? element) => contains(element) ? element as T : null;

  @override
  Iterator<T> get iterator => _itens.keys.iterator;

  @override
  int get length => _itens.length;

  @override
  Set<T> toSet() => _itens.keys.toSet();
}
