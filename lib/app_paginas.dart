part of 'main.dart';

// Rodada 18: saiu do main.dart (achado A-32).

/// Onboarding de 3 telas, mostrado uma vez. Explica o app, avisa das
/// permissões que vêm a seguir e conecta o Google.
class OnboardingPage extends StatefulWidget {
  final GoogleSignInAccount? conta;
  final Future<void> Function() onLogin;
  final Future<void> Function() onConcluir;
  const OnboardingPage({
    super.key,
    required this.conta,
    required this.onLogin,
    required this.onConcluir,
  });

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}
class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pc = PageController();
  int _pagina = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Widget _tela(IconData icone, String titulo, String texto, {Widget? extra}) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 56, color: _actionBlue),
          const SizedBox(height: 24),
          Text(titulo,
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text(texto,
              style: TextStyle(
                  fontSize: 16, color: _inkMuted, height: 1.4)),
          if (extra != null) ...[const SizedBox(height: 24), extra],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _dependerDoTema(context);
    final ultima = _pagina == 2;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pc,
                onPageChanged: (p) => setState(() => _pagina = p),
                children: [
                  _tela(
                    Icons.photo_library_outlined,
                    'Celular cheio, memórias salvas',
                    'O Limpa Memória guarda suas fotos e vídeos no seu Google Drive, na qualidade original, e só depois apaga do celular o que conferiu que está seguro na nuvem.',
                  ),
                  _tela(
                    Icons.lock_open_outlined,
                    'Ele vai pedir 2 permissões',
                    'Acesso às fotos: pra listar e subir suas mídias.\n\nNotificações: pra você acompanhar o backup com a tela apagada.\n\nSó isso. Nada sai do celular além dos arquivos que VOCÊ mandar pro seu Drive.',
                  ),
                  _tela(
                    Icons.cloud_outlined,
                    'Conecte seu Google',
                    widget.conta == null
                        ? 'O backup vai pro Drive da sua conta Google. O app só enxerga a pasta que ele mesmo cria; o resto do seu Drive fica invisível pra ele.'
                        : 'Conectado como ${widget.conta!.email}. Tudo pronto.',
                    extra: widget.conta == null
                        ? FilledButton.icon(
                            onPressed: () async {
                              await widget.onLogin();
                              if (mounted) setState(() {});
                            },
                            icon: const Icon(Icons.login),
                            label: const Text('Entrar com Google'),
                          )
                        : null,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
              child: Row(
                children: [
                  ...List.generate(
                    3,
                    (i) => Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _pagina ? _actionBlue : _hairline,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (!ultima)
                    TextButton(
                        onPressed: widget.onConcluir,
                        child: const Text('Pular')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: ultima
                        ? widget.onConcluir
                        : () => _pc.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut),
                    child: Text(ultima ? 'Começar' : 'Avançar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class PreviewPage extends StatefulWidget {
  final AssetEntity asset;
  final String caminho; // caminho real (MediaStore): abre sem copiar
  const PreviewPage(this.asset, {super.key, this.caminho = ''});
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}
class _PreviewPageState extends State<PreviewPage> {
  VideoPlayerController? _video;
  Uint8List? _imagem;
  bool _carregando = true;
  bool get _isVideo => widget.asset.type == AssetType.video;

  @override
  void initState() {
    super.initState();
    _preparar();
  }

  Future<void> _preparar() async {
    try {
      if (_isVideo) {
        File? f;
        if (widget.caminho.isNotEmpty) {
          final direto = File(widget.caminho);
          if (await direto.exists()) f = direto;
        }
        f ??= await widget.asset.file;
        if (f != null) {
          final c = VideoPlayerController.file(f);
          await c.initialize();
          await c.setLooping(true);
          await c.play();
          if (!mounted) {
            await c.dispose();
            return;
          }
          setState(() {
            _video = c;
            _carregando = false;
          });
          return;
        }
      } else {
        // Imagem: versão reduzida (1600 px) em vez dos bytes originais.
        // Foto de 50 MP decodificada inteira estourava memória.
        final bytes = await widget.asset
            .thumbnailDataWithSize(const ThumbnailSize(1600, 1600),
                quality: 90);
        if (mounted) {
          setState(() {
            _imagem = bytes;
            _carregando = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _carregando = false);
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _dependerDoTema(context);
    Widget corpo;
    if (_carregando) {
      corpo = const CircularProgressIndicator();
    } else if (_isVideo && _video != null) {
      final ar = _video!.value.aspectRatio;
      corpo = AspectRatio(
        aspectRatio: ar == 0 ? 16 / 9 : ar,
        child: VideoPlayer(_video!),
      );
    } else if (!_isVideo && _imagem != null) {
      corpo = Image.memory(_imagem!);
    } else {
      corpo = const Text('Não deu pra abrir',
          style: TextStyle(color: Colors.white));
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.asset.title ?? 'Prévia')),
      backgroundColor: Colors.black,
      body: Center(child: corpo),
      floatingActionButton: (_isVideo && _video != null)
          ? FloatingActionButton(
              onPressed: () => setState(() {
                _video!.value.isPlaying ? _video!.pause() : _video!.play();
              }),
              child: Icon(
                  _video!.value.isPlaying ? Icons.pause : Icons.play_arrow),
            )
          : null,
    );
  }
}
/// Ajustes (rodada 13): o que antes eram ícones soltos na barra de cima.
class AjustesPage extends StatefulWidget {
  final bool soWifi;
  final Future<void> Function(bool) onSoWifi;
  final VoidCallback? onEspaco;
  final VoidCallback onRecarregar;
  final VoidCallback onDiagnostico;
  final VoidCallback onHistorico;
  final bool motorNovo;
  final Future<void> Function(bool) onMotorNovo;
  final bool transferenciaLonga;
  final Future<void> Function(bool) onTransferenciaLonga;
  final bool lixeira;
  final bool lixeiraDisponivel;
  final Future<void> Function(bool) onLixeira;
  final VoidCallback onOrganizarPastas;
  final VoidCallback onCorrigirDatas;
  final Future<void> Function(String) onTema;
  const AjustesPage({
    super.key,
    required this.soWifi,
    required this.onSoWifi,
    required this.onEspaco,
    required this.onRecarregar,
    required this.onDiagnostico,
    required this.onHistorico,
    required this.motorNovo,
    required this.onMotorNovo,
    required this.transferenciaLonga,
    required this.onTransferenciaLonga,
    required this.lixeira,
    required this.lixeiraDisponivel,
    required this.onLixeira,
    required this.onOrganizarPastas,
    required this.onCorrigirDatas,
    required this.onTema,
  });

  @override
  State<AjustesPage> createState() => _AjustesPageState();
}
class _AjustesPageState extends State<AjustesPage> {
  late bool _soWifi = widget.soWifi;
  late bool _motorNovo = widget.motorNovo;
  late bool _transfLonga = widget.transferenciaLonga;
  late bool _lixeira = widget.lixeira;
  bool? _bateria;

  @override
  void initState() {
    super.initState();
    Nativo.bateriaIsenta().then((v) {
      if (mounted) setState(() => _bateria = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    _dependerDoTema(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        children: [
          SwitchListTile(
            value: _soWifi,
            title: const Text('Subir só no wifi'),
            subtitle: const Text(
                'Desligado: usa wifi e dados móveis. Ligado: espera uma rede wifi.'),
            onChanged: (v) async {
              setState(() => _soWifi = v);
              await widget.onSoWifi(v);
            },
          ),
          ListTile(
            title: const Text('Economia de bateria'),
            subtitle: Text(_bateria == null
                ? '…'
                : (_bateria!
                    ? 'Liberado: o Android não pausa o backup de madrugada.'
                    : 'O Android pode pausar backups longos. Toque pra liberar.')),
            trailing: Icon(
                _bateria == true ? Icons.check_circle : Icons.battery_alert,
                color: _bateria == true ? _actionBlue : _inkMuted),
            onTap: _bateria == true
                ? null
                : () async {
                    await Nativo.pedirIsencaoBateria();
                    final v = await Nativo.bateriaIsenta();
                    if (mounted) setState(() => _bateria = v);
                  },
          ),
          ListTile(
            title: const Text('Aparência'),
            leading: const Icon(Icons.dark_mode_outlined),
            trailing: DropdownButton<String>(
              value: _temaApp.value,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'sistema', child: Text('Automático')),
                DropdownMenuItem(value: 'claro', child: Text('Claro')),
                DropdownMenuItem(value: 'escuro', child: Text('Escuro')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                await widget.onTema(v);
                if (mounted) setState(() {});
              },
            ),
          ),
          if (widget.lixeiraDisponivel)
            SwitchListTile(
              value: _lixeira,
              title: const Text('Apagar pra lixeira do celular'),
              subtitle: const Text(
                  'O que sai do celular fica 30 dias na lixeira da galeria antes de sumir. Mais seguro, mas o espaço só volta quando a lixeira esvazia.'),
              onChanged: (v) async {
                setState(() => _lixeira = v);
                await widget.onLixeira(v);
              },
            ),
          const Divider(),
          ListTile(
            title: const Text('Organizar pastas no Drive'),
            subtitle: const Text(
                'Separa pastas que tinham o mesmo nome, como o "Sent" das fotos e o dos vídeos do WhatsApp.'),
            leading: const Icon(Icons.drive_file_move_outline),
            onTap: () {
              Navigator.pop(context);
              widget.onOrganizarPastas();
            },
          ),
          ListTile(
            title: const Text('Corrigir datas no Drive'),
            subtitle: const Text(
                'Backups antigos ficaram com a data do envio. Isso coloca a data da foto ou do vídeo.'),
            leading: const Icon(Icons.event_outlined),
            onTap: () {
              Navigator.pop(context);
              widget.onCorrigirDatas();
            },
          ),
          const Divider(),
          ListTile(
            title: const Text('Histórico de backups'),
            leading: const Icon(Icons.history),
            onTap: widget.onHistorico,
          ),
          ListTile(
            title: const Text('Espaço no Drive'),
            leading: const Icon(Icons.cloud_outlined),
            enabled: widget.onEspaco != null,
            onTap: widget.onEspaco,
          ),
          ListTile(
            title: const Text('Recarregar galeria'),
            subtitle: const Text('Depois de tirar fotos novas ou mudar permissões.'),
            leading: const Icon(Icons.refresh),
            onTap: () {
              Navigator.pop(context);
              widget.onRecarregar();
            },
          ),
          ListTile(
            title: const Text('Diagnóstico'),
            subtitle: const Text('Detalhes técnicos pra mandar se algo travar.'),
            leading: const Icon(Icons.bug_report_outlined),
            onTap: widget.onDiagnostico,
          ),
          const Divider(),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('Em teste',
                style: TextStyle(color: _inkMuted, fontSize: 12)),
          ),
          SwitchListTile(
            value: _transfLonga,
            title: const Text('Transferência longa (Android 14+)'),
            subtitle: const Text(
                'Usa o modo do Android feito pra envios grandes. Pode ajudar backups de madrugada a não pararem.'),
            onChanged: (v) async {
              setState(() => _transfLonga = v);
              await widget.onTransferenciaLonga(v);
            },
          ),
          SwitchListTile(
            value: _motorNovo,
            title: const Text('Motor novo (experimental)'),
            subtitle: const Text(
                'Envia vídeos em partes e continua de onde parou se a rede cair. Use só pra teste.'),
            onChanged: (v) async {
              setState(() => _motorNovo = v);
              await widget.onMotorNovo(v);
            },
          ),
          Padding(
            padding: EdgeInsets.all(16),
            child: Text('Limpa Memória $_versao',
                style: TextStyle(color: _inkMuted, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
/// Histórico das sessões de backup (lê o sessoes.jsonl).
class HistoricoPage extends StatelessWidget {
  final List<Map<String, Object?>> sessoes;
  const HistoricoPage({super.key, required this.sessoes});

  static String _data(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (d == null) return '-';
    String d2(int n) => n.toString().padLeft(2, '0');
    return '${d2(d.day)}/${d2(d.month)}/${d.year} ${d2(d.hour)}:${d2(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    _dependerDoTema(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Histórico')),
      body: sessoes.isEmpty
          ? Center(
              child: Text('Nenhum backup terminado ainda.',
                  style: TextStyle(color: _inkMuted)))
          : ListView.separated(
              itemCount: sessoes.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final s = sessoes[i];
                final arquivos = (s['arquivos'] as num?)?.toInt() ?? 0;
                final enviados = (s['enviados'] as num?)?.toInt() ?? arquivos;
                final bytes = (s['bytes'] as num?)?.toInt() ?? 0;
                final falhas = (s['falhas'] as num?)?.toInt() ?? 0;
                final ini = DateTime.tryParse('${s['inicio'] ?? ''}');
                final fim = DateTime.tryParse('${s['fim'] ?? ''}');
                final dur = (ini != null && fim != null)
                    ? fim.difference(ini)
                    : Duration.zero;
                final durTxt = dur.inHours > 0
                    ? '${dur.inHours}h${(dur.inMinutes % 60).toString().padLeft(2, '0')}'
                    : '${dur.inMinutes} min';
                return ListTile(
                  leading: Icon(
                      falhas == 0 ? Icons.cloud_done : Icons.error_outline,
                      color: falhas == 0 ? _actionBlue : _inkMuted),
                  title: Text(
                      '${milhar(enviados)} de ${milhar(arquivos)} arquivos · ${fmtBytes(bytes)}'),
                  subtitle: Text(
                      '${_data(s['fim'])} · durou $durTxt${falhas > 0 ? ' · ${milhar(falhas)} não subiram' : ''}'),
                );
              },
            ),
    );
  }
}
