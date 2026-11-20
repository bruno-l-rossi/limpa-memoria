part of 'main.dart';

// Rodada 18: saiu do main.dart (achado A-32).
// Pedaços de tela da Home: card, banner, abas, barras e diálogos.

extension _Telas on _HomePageState {
  void _mostrarVitoria(int arquivos, int bytes) {
    final liberaveis = _bytesSeguros;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup concluído!'),
        content: Text(
            '$arquivos arquivos (${_fmt(bytes)}) estão seguros no Drive.\n\n'
            '${liberaveis > 0 ? 'Agora dá pra liberar ${_fmt(liberaveis)} do celular.' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Nativo.compartilhar(
                'Acabei de guardar $arquivos fotos e vídeos (${_fmt(bytes)}) na nuvem e liberar espaço no celular com o Limpa Memória.'),
            child: const Text('Compartilhar'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(liberaveis > 0 ? 'Depois' : 'Fechar')),
          if (liberaveis > 0)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _apagarEnviados();
              },
              child: Text('Liberar ${_fmt(liberaveis)}'),
            ),
        ],
      ),
    );
  }
  /// Android 14+ deixa o usuário liberar só ALGUMAS fotos. O app então vê só
  /// essas e o backup sai incompleto sem ninguém perceber. Avisa e leva pro
  /// ajuste.
  Widget _avisoAcessoParcial() {
    if (!_acessoParcial) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      decoration: BoxDecoration(
        color: _avisoFundo,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              'O app só enxerga parte das suas fotos. Pro backup pegar tudo, permita acesso a todas.',
              style: TextStyle(fontSize: 13, color: _ink)),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: () async {
                    await PhotoManager.openSetting();
                  },
                  child: const Text('Abrir ajustes')),
              TextButton(
                  onPressed: _recarregarGaleria,
                  child: const Text('Já liberei')),
            ],
          ),
        ],
      ),
    );
  }
  Future<void> _abrirDiagnostico() async {
    _calcStats();
    final isenta = await Nativo.bateriaIsenta();
    final eventos = await _store.ultimosEventos(max: 300);
    if (!mounted) return;
    final resumo = [
      'Limpa Memória $_versao',
      'Conta: ${_conta?.email ?? 'não conectada'}',
      'Galeria: ${_milhar(_items.length)} itens · acesso ${_acessoTotal ? 'total' : (_acessoParcial ? 'PARCIAL' : 'negado')}',
      'Enviados no store: ${_milhar(_enviadosIds.length)}',
      'Sessão: ${_milhar(_cFeitos)} de ${_milhar(_bgTotal)} · ${_fmt(_cBytesFeitos)} de ${_fmt(_cBytesTotal)}',
      'Fila: ${_milhar(_pendentes.length)} · no Android: ${_emAndamento.length} · preparando: ${_preparando.length} · conferindo: ${_processando.length} · em partes: ${_emRetomavel.length}',
      'Motor novo: ${_motorNovo ? 'ligado' : 'desligado'} · transferência longa: ${_transferenciaLonga ? 'ligada' : 'desligada'}',
      'Falhos: ${_falhos.length} · pausado: ${_pausado ? 'sim' : 'não'}${_driveCheio ? ' (Drive cheio)' : ''} · sem rede: ${_semRede ? 'sim' : 'não'}',
      'Nesta execução: ${_milhar(_arquivosSessao)} arquivos, ${_fmt(_bytesSessao)} · ${_fmt(_velocidade.round())}/s',
      'Bateria isenta: ${isenta ? 'sim' : 'NÃO'} · só wifi: ${_soWifi ? 'sim' : 'não'}',
      'Último erro: ${_erroBg ?? '-'}',
      '',
      'Por tamanho (nesta execução):',
      _telemetria.texto(),
    ].join('\n');
    final ultimos = eventos.reversed.take(60).join('\n');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Diagnóstico'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              '$resumo\n\nÚltimos eventos (mais recente primeiro):\n${ultimos.isEmpty ? '-' : ultimos}',
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Nativo.compartilhar(
                '$resumo\n\nEventos:\n${eventos.join('\n')}'),
            child: const Text('Compartilhar'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Fechar')),
        ],
      ),
    );
  }
  /// Card no topo: o resumo da missão e os 2 botões que resolvem a jornada.
  Widget _cardMissao() {
    if (_items.isEmpty) return const SizedBox.shrink();
    final subindo =
        _emFila.isNotEmpty && _bgFeitos < _bgTotal && !_fimComFalhas;
    if (subindo) return const SizedBox.shrink(); // durante o backup, o banner manda
    final liberaveis = _bytesSeguros;
    final foraDrive = max(0, _bytesNoCelular - liberaveis);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _parchment,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Seu celular tem ${_fmt(_bytesNoCelular)} em fotos e vídeos',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, color: _ink),
          ),
          const SizedBox(height: 4),
          Text(
            liberaveis > 0
                ? '${_fmt(liberaveis)} já estão seguros no Drive e podem sair do celular. ${foraDrive > 0 ? '${_fmt(foraDrive)} ainda estão só aqui.' : ''}'
                : '${_fmt(foraDrive)} ainda estão só no celular.',
            style: TextStyle(fontSize: 13, color: _inkMuted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton(
                onPressed: _abrirSugestoes,
                child: const Text('Liberar espaço'),
              ),
              if (liberaveis > 0)
                TextButton(
                  onPressed: _apagarEnviados,
                  child: Text('Apagar ${_fmt(liberaveis)} seguros'),
                ),
            ],
          ),
        ],
      ),
    );
  }
  /// Sugestões de seleção (estilo Files by Google): grupos prontos com o
  /// quanto cada um libera. Heurísticas baratas de pasta, tamanho e data.
  Future<void> _abrirSugestoes() async {
    // Sem conta: abre o login aqui mesmo e segue (antes só avisava).
    if (_conta == null) {
      await _login();
      if (_conta == null || !mounted) return;
    }
    final fora = [
      for (final m in _items)
        if (!_enviadosIds.contains(m.id)) m
    ];
    final porId = {for (final m in fora) m.id: m};
    final grupos = montarSugestoes([
      for (final m in fora)
        MidiaSugestao(m.id, m.video, m.bytes, m.caminhoRel,
            m.asset.createDateTime)
    ]);
    final bytesFora = fora.fold<int>(0, (s, m) => s + m.bytes);

    if (fora.isEmpty) {
      _avisar('Tudo que está no celular já está no Drive.');
      return;
    }

    final marcados = <int>{for (var i = 0; i < grupos.length; i++) i};
    var tudo = grupos.isEmpty; // sem sugestão óbvia: oferece "tudo"
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final selecionados = <MediaItem>{};
          if (tudo) {
            selecionados.addAll(fora);
          } else {
            for (final i in marcados) {
              for (final id in grupos[i].ids) {
                final m = porId[id];
                if (m != null) selecionados.add(m);
              }
            }
          }
          final bytes = selecionados.fold<int>(0, (s, m) => s + m.bytes);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('O que guardar no Drive?',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                        grupos.isEmpty
                            ? 'Nada óbvio pra sugerir. Dá pra guardar tudo que ainda falta.'
                            : 'Sugestões prontas. Um arquivo pode estar em mais de um grupo, mas só sobe uma vez.',
                        style:
                            TextStyle(fontSize: 13, color: _inkMuted)),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      value: tudo,
                      onChanged: (v) => setSheet(() => tudo = v),
                      title: const Text('Tudo que ainda não está no Drive'),
                      subtitle: Text(
                          '${_milhar(fora.length)} arquivos · ${_fmt(bytesFora)}'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (!tudo)
                      ...List.generate(grupos.length, (i) {
                        final g = grupos[i];
                        return CheckboxListTile(
                          value: marcados.contains(i),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              marcados.add(i);
                            } else {
                              marcados.remove(i);
                            }
                          }),
                          title: Text(g.titulo),
                          subtitle: Text(
                              '${g.descricao} · ${_milhar(g.ids.length)} arquivos · ${_fmt(g.bytes)}'),
                          contentPadding: EdgeInsets.zero,
                        );
                      }),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: selecionados.isEmpty
                            ? null
                            : () {
                                Navigator.pop(ctx);
                                _set(() {
                                  _selected
                                    ..clear()
                                    ..addAll(selecionados);
                                });
                                _subir();
                              },
                        child: Text(selecionados.isEmpty
                            ? 'Nada marcado'
                            : 'Guardar ${_milhar(selecionados.length)} arquivos (${_fmt(bytes)})'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
  Widget _barraAcoes({bool pastas = false}) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          TextButton.icon(
              onPressed: pastas
                  ? () => _set(() => _selected.addAll(_items))
                  : _selecionarTudo,
              icon: const Icon(Icons.done_all),
              label: Text(pastas || (_filtro == 'todos' && _tipo == 'todos')
                  ? 'Selecionar tudo'
                  : 'Selecionar estes')),
          TextButton(
              onPressed: _selected.isEmpty ? null : _limparSelecao,
              child: const Text('Limpar')),
          const Spacer(),
          PopupMenuButton<String>(
            icon: Icon(Icons.tune,
                color: (!pastas && _tipo != 'todos') ? _actionBlue : null),
            tooltip: 'Ordenar e filtrar',
            onSelected: (v) => _set(() {
              if (v.startsWith('tipo:')) {
                _tipo = v.substring(5);
                _filtradoCache = null;
              } else {
                _ordem = v;
                _ordenadoCache = null;
              }
            }),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                  value: 'tamanho',
                  checked: _ordem == 'tamanho',
                  child: const Text('Maiores primeiro')),
              CheckedPopupMenuItem(
                  value: 'data',
                  checked: _ordem == 'data',
                  child: const Text('Mais recentes primeiro')),
              if (!pastas) ...[
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                    value: 'tipo:todos',
                    checked: _tipo == 'todos',
                    child: const Text('Fotos e vídeos')),
                CheckedPopupMenuItem(
                    value: 'tipo:fotos',
                    checked: _tipo == 'fotos',
                    child: const Text('Só fotos')),
                CheckedPopupMenuItem(
                    value: 'tipo:videos',
                    checked: _tipo == 'videos',
                    child: const Text('Só vídeos')),
              ],
            ],
          ),
        ],
      ),
    );
  }
  Widget _botaoConta() {
    if (_conta == null) {
      return TextButton(onPressed: _login, child: const Text('Entrar'));
    }
    return PopupMenuButton<String>(
      tooltip: _conta!.email,
      icon: const Icon(Icons.account_circle),
      onSelected: (v) {
        switch (v) {
          case 'espaco':
            _checarEspaco();
          case 'sair':
            _logout();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Text(_conta!.email,
              style: TextStyle(color: _inkMuted, fontSize: 13)),
        ),
        const PopupMenuItem(value: 'espaco', child: Text('Espaço no Drive')),
        const PopupMenuItem(value: 'sair', child: Text('Sair da conta')),
      ],
    );
  }
  Future<void> _abrirAjustes() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AjustesPage(
          soWifi: _soWifi,
          onSoWifi: (v) async {
            await _store.setSoWifi(v);
            if (mounted) _set(() => _soWifi = v);
          },
          onEspaco: _conta == null ? null : _checarEspaco,
          onRecarregar: _recarregarGaleria,
          onDiagnostico: _abrirDiagnostico,
          onHistorico: _abrirHistorico,
          motorNovo: _motorNovo,
          transferenciaLonga: _transferenciaLonga,
          onTransferenciaLonga: (v) async {
            await _store.setFlag(UploadStore.kTransferenciaLonga, v);
            if (mounted) _set(() => _transferenciaLonga = v);
          },
          onMotorNovo: (v) async {
            await _store.setFlag(UploadStore.kMotorNovo, v);
            if (mounted) _set(() => _motorNovo = v);
          },
          lixeira: _lixeira,
          lixeiraDisponivel: _sdk >= 30,
          onLixeira: (v) async {
            await _store.setFlag(UploadStore.kLixeira, v);
            if (mounted) _set(() => _lixeira = v);
          },
          onTema: (v) async {
            _temaApp.value = v;
            await _store.setTexto(UploadStore.kTema, v);
          },
          onOrganizarPastas: _organizarPastas,
          onCorrigirDatas: _corrigirDatas,
        ),
      ),
    );
  }
  Widget _telaPermissao() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined,
                size: 56, color: _actionBlue),
            const SizedBox(height: 16),
            const Text('O app precisa ver suas fotos e vídeos',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
                'Sem esse acesso não dá pra listar nem guardar nada. Libere em Ajustes > Permissões > Fotos e vídeos > Permitir tudo.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _inkMuted)),
            const SizedBox(height: 20),
            FilledButton(
                onPressed: () => PhotoManager.openSetting(),
                child: const Text('Abrir ajustes')),
            TextButton(
                onPressed: () {
                  _set(() {
                    _permissaoNegada = false;
                    _loading = true;
                  });
                  _load();
                },
                child: const Text('Já liberei, tentar de novo')),
          ],
        ),
      ),
    );
  }
  /// Esqueleto da grade enquanto a galeria carrega (antes: texto solto).
  Widget _telaCarregando() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_status, style: TextStyle(color: _inkMuted)),
        ),
        Expanded(
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
            itemCount: 18,
            itemBuilder: (_, _) => Container(color: _parchment),
          ),
        ),
      ],
    );
  }
  Widget _telaVazia() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_status, style: TextStyle(color: _inkMuted)),
          TextButton(
              onPressed: _recarregarGaleria,
              child: const Text('Recarregar')),
        ],
      ),
    );
  }
  Future<void> _abrirHistorico() async {
    final sessoes = await _store.ultimasSessoes();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => HistoricoPage(sessoes: sessoes)),
    );
  }
  /// Lista dos arquivos que não subiram, com o motivo de cada um.
  Future<void> _mostrarFalhas() async {
    final itens = _falhos.values.toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('${_milhar(itens.length)} arquivos não subiram',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: itens.length,
                  itemBuilder: (_, i) {
                    final it = itens[i];
                    return ListTile(
                      dense: true,
                      title: Text(it.titulo),
                      subtitle: Text(
                          '${it.pasta} · ${_fmt(it.bytes)}\n${_motivoFalha[it.id] ?? 'Motivo desconhecido'}'),
                      isThreeLine: true,
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _tentarFalhosDeNovo();
                    },
                    child: const Text('Tentar todos de novo'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _bannerBackup() {
    if (_emFila.isEmpty) return const SizedBox.shrink();
    _calcStats();
    final total = _bgTotal;
    final feitos = _cFeitos;
    final pronto = feitos >= total;
    final fimFalhas = !pronto && _fimComFalhas;
    final bytesTotal = _cBytesTotal;
    final bytesFeitos = _cBytesFeitos;
    final pct = bytesTotal > 0
        ? bytesFeitos / bytesTotal
        : (total == 0 ? 0.0 : feitos / total);
    final faltam = total - feitos;
    final eta = (!pronto && !_pausado && !fimFalhas)
        ? _eta(bytesTotal - bytesFeitos)
        : '';
    final vel = _velocidade;
    final liberaveis = _bytesSeguros;

    final String titulo;
    if (pronto) {
      titulo = 'Backup concluído: ${_milhar(feitos)} arquivos no Drive';
    } else if (fimFalhas) {
      titulo =
          'Backup parou: ${_milhar(feitos)} de ${_milhar(total)} · ${_milhar(faltam)} não subiram';
    } else if (_pausado) {
      titulo = 'Backup pausado: ${_milhar(feitos)} de ${_milhar(total)}';
    } else {
      titulo = 'Subindo backup: ${_milhar(feitos)} de ${_milhar(total)}';
    }

    final String? detalhe;
    if (pronto || fimFalhas) {
      detalhe = null;
    } else if (_pausado) {
      detalhe =
          'Pausado · faltam ${_milhar(faltam)} · toque em Retomar pra continuar';
    } else if (_conta == null) {
      detalhe = 'Entre com o Google (ícone lá em cima) pra continuar.';
    } else if (_semRede) {
      detalhe =
          'Sem internet ou o Drive pediu pausa. Continua sozinho quando voltar · na fila: ${_milhar(_pendentes.length)}';
    } else {
      detalhe =
          'Subindo agora: ${_emAndamento.length + _preparando.length} · na fila: ${_milhar(_pendentes.length)}'
          '${eta.isNotEmpty ? ' · $eta' : ''}'
          '${vel > 0 ? ' · ${_fmt(vel.round())}/s' : ''}';
    }

    return Container(
      width: double.infinity,
      color: _parchment,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  pronto
                      ? Icons.cloud_done
                      : (fimFalhas
                          ? Icons.error_outline
                          : (_pausado
                              ? Icons.pause_circle
                              : (_semRede
                                  ? Icons.cloud_off
                                  : Icons.cloud_upload))),
                  size: 18,
                  color: _actionBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(titulo,
                    style: TextStyle(fontSize: 14, color: _ink)),
              ),
              if (!pronto && !fimFalhas)
                _pausado
                    ? TextButton.icon(
                        onPressed: _conta == null ? null : _retomar,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Retomar'))
                    : TextButton.icon(
                        onPressed: _parar,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('Parar')),
              if ((pronto || fimFalhas) && liberaveis > 0)
                TextButton.icon(
                    onPressed: _apagarEnviados,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text('Liberar ${_fmt(liberaveis)}')),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 6,
              backgroundColor: _hairline,
              value: pct.clamp(0.0, 1.0),
            ),
          ),
          if (detalhe != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(detalhe,
                  style: TextStyle(fontSize: 12, color: _inkMuted)),
            ),
          // Rodada 18: a dica aparece até o usuário tocar em "Entendi"
          // (antes ficava fixa em 5 lugares: banner, notificação, avisos).
          if (!pronto &&
              !_pausado &&
              !fimFalhas &&
              _conta != null &&
              !_dicaAbertoVista)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        'Dica: com o app aberto e o celular na tomada, o backup vai até o fim.',
                        style: TextStyle(fontSize: 12, color: _inkMuted)),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    onPressed: () {
                      _set(() => _dicaAbertoVista = true);
                      _store.setFlag(UploadStore.kDicaAberto, true);
                    },
                    child: const Text('Entendi'),
                  ),
                ],
              ),
            ),
          if (_falhos.isNotEmpty || _erroBg != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _erroBg != null
                          ? mensagemAmigavel(_erroBg)
                          : '${_milhar(_falhos.length)} arquivo(s) não subiram.',
                      style:
                          TextStyle(fontSize: 12, color: _erroTexto),
                    ),
                  ),
                  if (_falhos.isNotEmpty && !_driveCheio)
                    TextButton(
                        onPressed: _mostrarFalhas,
                        child: Text('Ver ${_milhar(_falhos.length)}')),
                ],
              ),
            ),
        ],
      ),
    );
  }
  Widget _filtroDrive() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'todos', label: Text('Todos')),
            ButtonSegment(value: 'foradrive', label: Text('Fora')),
            ButtonSegment(value: 'drive', label: Text('No Drive')),
          ],
          selected: {_filtro},
          showSelectedIcon: false,
          onSelectionChanged: (s) => _set(() => _filtro = s.first),
        ),
      ),
    );
  }
  Widget _abaMidias() {
    final lista = _itensFiltrados;
    return Column(
      children: [
        _barraAcoes(),
        _filtroDrive(),
        Expanded(
          child: lista.isEmpty
              ? Center(
                  child: Text(
                      _filtro == 'drive'
                          ? 'Nada no Drive ainda.'
                          : (_filtro == 'foradrive'
                              ? 'Tudo já está no Drive.'
                              : 'Nada por aqui.'),
                      style: TextStyle(color: _inkMuted)))
              : _grade(lista),
        ),
      ],
    );
  }
  /// Lado da miniatura em pixels físicos, pelo tamanho real da célula (antes
  /// 200 fixo: borrava em tela 1080p). Teto de 360 pra não pesar.
  int _ladoThumb(BuildContext context) {
    final mq = MediaQuery.of(context);
    final lado = (mq.size.width / 3) * mq.devicePixelRatio;
    return lado.clamp(150, 360).round();
  }
  Widget _grade(List<MediaItem> lista, {VoidCallback? aoMudar}) {
    return _GradeMidias(
      lista: lista,
      lado: _ladoThumb(context),
      selecionado: _selected.contains,
      noDrive: (m) => _enviadosIds.contains(m.id),
      tamanho: (m) => _fmt(m.bytes),
      temSelecao: () => _selected.isNotEmpty,
      marcar: (m, v) => v ? _selected.add(m) : _selected.remove(m),
      aoTocar: (item) {
        _toggle(item);
        aoMudar?.call();
        _dicaPreviaUmaVez();
      },
      aoArrastar: () {
        _set(() {});
        aoMudar?.call();
      },
      aoSegurar: (item) => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => PreviewPage(item.asset, caminho: item.path))),
    );
  }
  /// Barra de baixo: quanto está selecionado + Subir. [fechar] = está numa
  /// página por cima (pasta) e volta pra tela principal antes de subir.
  Widget _barraSubir({bool fechar = false}) {
    return Container(
      decoration: BoxDecoration(
        color: _parchment,
        border: Border(top: BorderSide(color: _hairline)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                  child: Text(
                      '${_milhar(_selected.length)} selecionados • ${_fmt(_totalSelecionado)}')),
              FilledButton(
                  onPressed: _selected.isEmpty || _subindoAgora
                      ? null
                      : () {
                          if (fechar) Navigator.pop(context);
                          _subir();
                        },
                  child: const Text('Guardar no Drive')),
            ],
          ),
        ),
      ),
    );
  }
  /// Na primeira seleção, ensina que segurar abre a prévia (antes ninguém
  /// descobria).
  Future<void> _dicaPreviaUmaVez() async {
    if (_dicaMostrada) return;
    _dicaMostrada = true;
    if (await _store.flag(UploadStore.kDicaPrevia)) return;
    await _store.setFlag(UploadStore.kDicaPrevia, true);
    _avisar('Dica: segure e arraste pra marcar vários de uma vez. Sem nada marcado, segurar abre em tela cheia.');
  }
  /// Abre a grade de UMA pasta (antes a aba Pastas só tinha checkbox).
  Future<void> _abrirPasta(Pasta p) async {
    final itens = List<MediaItem>.of(p.itens)
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatefulBuilder(
          builder: (ctx, setPagina) => Scaffold(
            appBar: AppBar(
              title: Text(p.nome),
              actions: [
                TextButton(
                  onPressed: () {
                    _togglePasta(p, _estadoPasta(p) != true);
                    setPagina(() {});
                  },
                  child: Text(_estadoPasta(p) == true
                      ? 'Desmarcar todos'
                      : 'Marcar todos'),
                ),
              ],
            ),
            body: _grade(itens, aoMudar: () => setPagina(() {})),
            bottomNavigationBar: _barraSubir(fechar: true),
          ),
        ),
      ),
    );
    if (mounted) _set(() {});
  }
  Widget _abaPastas() {
    final subiuMapa = _subiuPorPastaMapa;
    return Column(
      children: [
        _barraAcoes(pastas: true),
        Expanded(
          child: ListView.builder(
            itemCount: _pastas.length,
            itemBuilder: (context, i) {
              final p = _pastas[i];
              final subiu = subiuMapa[p.nome] ?? 0;
              final todos = p.itens.length;
              final tudoNoDrive = todos > 0 && subiu >= todos;
              final estado = _estadoPasta(p);
              return ListTile(
                onTap: () => _abrirPasta(p),
                leading: Checkbox(
                  tristate: true,
                  value: estado,
                  // Parcial -> toque seleciona a pasta toda.
                  onChanged: (_) => _togglePasta(p, estado != true),
                ),
                trailing: tudoNoDrive
                    ? Icon(Icons.cloud_done, color: _actionBlue)
                    : (subiu > 0
                        ? Text('${_milhar(subiu)}/${_milhar(todos)}',
                            style: TextStyle(
                                fontSize: 12, color: _inkMuted))
                        : null),
                title: Text(p.nome),
                subtitle: Text(
                    '${_milhar(p.itens.length)} arquivos • ${_fmt(p.bytes)}${tudoNoDrive ? ' • no Drive' : ''}'),
              );
            },
          ),
        ),
      ],
    );
  }
}
