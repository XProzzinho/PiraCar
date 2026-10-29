import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'aviso.dart';
import 'carro_icone.dart';
import 'categorias.dart';
import 'chat_corrida.dart';
import 'foto.dart';
import 'lugares.dart';
import 'menu_lateral.dart';
import 'rota.dart';
import 'cores.dart';

// Preço: valor fixo até X km; depois, valor por km extra (proporcional).
// O admin muda em config/app (precoBase, kmIncluidos, precoKm).
var _valorBase = 10.0;
var _kmIncluidos = 3.0;
var _precoKmExtra = 1.76;

double _numCfg(dynamic v, double padrao) =>
    v is num && v > 0 ? v.toDouble() : padrao;

double _calcularValor(double km) {
  if (km <= _kmIncluidos) return _valorBase;
  return double.parse(
      (_valorBase + (km - _kmIncluidos) * _precoKmExtra).toStringAsFixed(2));
}

// Desenha um ícone (o carrinho) dentro de um círculo colorido.
Future<BitmapDescriptor> _criarIcone(IconData icone, Color cor,
    {double tam = 110}) async {
  final gravador = ui.PictureRecorder();
  final canvas = Canvas(gravador);
  final centro = Offset(tam / 2, tam / 2);
  canvas.drawCircle(centro, tam / 2, Paint()..color = Colors.white);
  canvas.drawCircle(centro, tam / 2 - 7, Paint()..color = cor);
  final tp = TextPainter(textDirection: TextDirection.ltr)
    ..text = TextSpan(
      text: String.fromCharCode(icone.codePoint),
      style: TextStyle(
        fontSize: tam * 0.58,
        fontFamily: icone.fontFamily,
        package: icone.fontPackage,
        color: Colors.white,
      ),
    )
    ..layout();
  tp.paint(canvas, Offset((tam - tp.width) / 2, (tam - tp.height) / 2));
  final img =
      await gravador.endRecording().toImage(tam.toInt(), tam.toInt());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  // ignore: deprecated_member_use
  return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
}

/// Motorista online e livre, para mostrar no mapa.
class _Livre {
  final String id;
  final LatLng pos;
  final double direcao;

  /// Quando ESTE celular viu o sinal do motorista mudar pela última vez.
  /// (Não usa o relógio do servidor: se o relógio do celular estiver
  /// adiantado ou atrasado, o motorista sumia da lista e o pedido sumia
  /// da tela dele.)
  final DateTime visto;

  /// Motorista terminando uma corrida, perto de deixar o passageiro: pode
  /// receber a próxima e vir depois.
  final bool quaseLivre;

  /// Onde ele vai ficar livre (destino da corrida atual) e quanto falta.
  final LatLng? livreEm;
  final double restante;
  final List<String> categorias;
  _Livre(this.id, this.pos, this.direcao, this.visto,
      {this.quaseLivre = false,
      this.livreEm,
      this.restante = 0,
      this.categorias = const ['piracar']});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _centroPirapora = LatLng(-17.3453, -44.9419);

  final _destino = TextEditingController();
  final _focoBusca = FocusNode();
  List<Sugestao> _sugestoes = [];
  bool _buscandoSug = false;
  Timer? _atrasoBusca;
  int _buscaId = 0;
  GoogleMapController? _mapa;
  LatLng? _posicao;
  LatLng? _destinoLL;
  String _destinoTexto = '';
  Rota? _rota;
  double? _valor; // valor base (PiraCar); cada categoria multiplica
  String _categoria = 'piracar';
  bool _motoAtiva = false;
  StreamSubscription<bool>? _subMoto;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subPreco;

  List<Categoria> get _categoriasVisiveis => [
        catPiracar,
        if (_motoAtiva) catMoto,
        catSedan,
        catConforto,
      ];

  double _precoDe(Categoria c) =>
      double.parse((_valor! * c.multiplicador).toStringAsFixed(2));
  String? _pagamento;
  String? _corridaId;
  bool _calculando = false;
  bool _pedindo = false;

  double _motoristaDir = 0;
  BitmapDescriptor _iconeCarro =
      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);

  // Acompanhamento do motorista em tempo real
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subCorrida;
  String? _status;
  bool _hospitais = false; // mostra a lista de hospitais no painel de busca
  // Radar pulsando no ponto do passageiro enquanto procura motorista.
  final _radar = ValueNotifier<double>(0);
  Timer? _radarTimer;
  LatLng? _motorista;
  Rota? _rotaMotorista;
  LatLng? _rotaOrigem;
  DateTime _rotaTentativa = DateTime.fromMillisecondsSinceEpoch(0);
  bool _buscandoRota = false;

  final _db = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser!.uid;

  static const _statusTexto = {
    'solicitada': 'Procurando motorista...',
    'aceita': 'Motorista a caminho',
    'em_andamento': 'Corrida em andamento',
    'finalizada': 'Corrida finalizada',
    'cancelada': 'Corrida cancelada',
  };

  static const _formas = {
    'credito': 'Crédito',
    'debito': 'Débito',
    'pix': 'Pix',
  };

  static const _icones = {
    'credito': Icons.credit_card,
    'debito': Icons.payment,
    'pix': Icons.qr_code_2,
  };

  static const _nomesPagamento = {
    'credito': 'Cartão de crédito',
    'debito': 'Cartão de débito',
    'pix': 'Pix',
  };

  // Motoristas disponíveis no mapa
  BitmapDescriptor? _iconeCarroCima;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subLivres;
  List<_Livre> _livres = [];
  Timer? _relogio;

  @override
  void initState() {
    super.initState();
    _subMoto = motoAtiva().listen((v) {
      if (!mounted) return;
      setState(() {
        _motoAtiva = v;
        if (!v && _categoria == 'moto') _categoria = 'piracar';
      });
    });
    _subPreco = _db.collection('config').doc('app').snapshots().listen((s) {
      final d = s.data() ?? const {};
      _valorBase = _numCfg(d['precoBase'], 10.0);
      _kmIncluidos = (d['kmIncluidos'] is num && (d['kmIncluidos'] as num) >= 0)
          ? (d['kmIncluidos'] as num).toDouble()
          : 3.0;
      _precoKmExtra = _numCfg(d['precoKm'], 1.76);
      // destino já escolhido e ainda sem pedir: atualiza o valor
      if (mounted && _rota != null && _corridaId == null) {
        setState(() => _valor = _calcularValor(_rota!.metros / 1000));
      }
    }, onError: (_) {});
    _carregarIcones();
    _localizar();
    _ouvirLivres();
  }

  void _ouvirLivres() {
    _subLivres = _db
        .collection('users')
        .where('role', isEqualTo: 'motorista')
        .where('online', isEqualTo: true)
        .snapshots()
        .listen((snap) {
      final lista = <_Livre>[];
      final agora = DateTime.now();
      for (final d in snap.docs) {
        final m = d.data();
        final gp = m['posicao'];
        if (gp is! GeoPoint) continue;
        final em = m['posicaoEm'];
        final dir = m['direcao'];
        // marca a hora (deste celular) em que o sinal mudou
        final anterior = _sinais[d.id];
        final visto =
            (anterior != null && anterior.$1 == em) ? anterior.$2 : agora;
        _sinais[d.id] = (em, visto);
        final le = m['livreEm'];
        final rest = m['restanteMetros'];
        lista.add(_Livre(
          d.id,
          LatLng(gp.latitude, gp.longitude),
          dir is num ? dir.toDouble() : 0,
          visto,
          quaseLivre: m['quaseLivre'] == true,
          livreEm: le is GeoPoint ? LatLng(le.latitude, le.longitude) : null,
          restante: rest is num ? rest.toDouble() : 0,
          categorias: categoriasDoMotorista(m),
        ));
      }
      if (mounted) setState(() => _livres = lista);
    }, onError: (_) {});
    // some com quem parou de mandar sinal (app fechado, sem internet)
    _relogio = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  final Map<String, (Object?, DateTime)> _sinais = {};

  /// Motoristas online com sinal recente (inclui os quase livres).
  List<_Livre> get _livresAgora {
    final agora = DateTime.now();
    return _livres
        .where((l) => agora.difference(l.visto).inSeconds < 70)
        .toList();
  }

  /// Só os livres de verdade (para mostrar o carrinho no mapa).
  List<_Livre> get _livresNoMapa =>
      _livresAgora.where((l) => !l.quaseLivre).toList();

  @override
  void dispose() {
    _radarTimer?.cancel();
    _radar.dispose();
    _atrasoBusca?.cancel();
    _focoBusca.dispose();
    _subLivres?.cancel();
    _subMoto?.cancel();
    _subPreco?.cancel();
    _relogio?.cancel();
    _despachante?.cancel();
    _subCorrida?.cancel();
    super.dispose();
  }

  Future<void> _carregarIcones() async {
    try {
      final carro =
          await _criarIcone(Icons.directions_car, Colors.green.shade700);
      final deCima = await criarCarroDeCima();
      if (!mounted) return;
      setState(() {
        _iconeCarro = carro;
        _iconeCarroCima = deCima;
      });
    } catch (_) {}
  }

  void _aviso(String msg, {int segundos = 4}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: Duration(seconds: segundos)),
    );
  }

  Future<void> _localizar() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return;
    final p = await Geolocator.getCurrentPosition();
    final ll = LatLng(p.latitude, p.longitude);
    if (!mounted) return;
    setState(() => _posicao = ll);
    _mapa?.animateCamera(CameraUpdate.newLatLngZoom(ll, 17));
  }

  void _ajustarCamera(List<LatLng> pts) {
    if (pts.length < 2) return;
    double minLat = pts.first.latitude, maxLat = minLat;
    double minLng = pts.first.longitude, maxLng = minLng;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    try {
      _mapa?.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        60,
      ));
    } catch (_) {}
  }

  // ---------- Busca de destino com sugestões ----------

  bool get _buscaAberta =>
      _focoBusca.hasFocus || _destino.text.trim().isNotEmpty;

  void _digitou(String texto) {
    _atrasoBusca?.cancel();
    setState(() {});
    if (texto.trim().length < 3) {
      setState(() {
        _sugestoes = [];
        _buscandoSug = false;
      });
      return;
    }
    setState(() => _buscandoSug = true);
    _atrasoBusca = Timer(const Duration(milliseconds: 350), () async {
      final id = ++_buscaId;
      final r = await buscarSugestoes(texto, _posicao);
      if (!mounted || id != _buscaId) return;
      setState(() {
        _sugestoes = r;
        _buscandoSug = false;
      });
    });
  }

  void _atalho(String texto) {
    _destino.text = texto;
    _destino.selection = TextSelection.collapsed(offset: texto.length);
    _focoBusca.requestFocus();
    _digitou(texto);
  }

  void _fecharBusca() {
    _atrasoBusca?.cancel();
    _destino.clear();
    _focoBusca.unfocus();
    setState(() {
      _sugestoes = [];
      _buscandoSug = false;
    });
  }

  Future<void> _escolher(Sugestao s) async {
    _focoBusca.unfocus();
    setState(() => _calculando = true);
    final local = await localDaSugestao(s);
    if (!mounted) return;
    if (local == null) {
      setState(() => _calculando = false);
      _aviso('Não consegui achar esse endereço. Tente outro.');
      return;
    }
    _destino.text = s.principal;
    await _calcularPara(local, s.principal);
    if (mounted) setState(() => _sugestoes = []);
  }

  // Passo 1: acha o destino, traça a rota pelas ruas e calcula o valor.
  Future<void> _calcular() async {
    if (_posicao == null || _destino.text.trim().isEmpty) return;
    setState(() => _calculando = true);
    try {
      final texto = _destino.text.trim();
      final locs = await locationFromAddress('$texto, Pirapora, MG');
      if (locs.isEmpty) throw 'Endereço não encontrado';
      final destino = LatLng(locs.first.latitude, locs.first.longitude);
      await _calcularPara(destino, texto);
    } catch (e) {
      _aviso('$e');
    } finally {
      if (mounted) setState(() => _calculando = false);
    }
  }

  Future<void> _calcularPara(LatLng destino, String texto) async {
    if (_posicao == null) {
      _aviso('Ainda estou pegando a sua localização.');
      setState(() => _calculando = false);
      return;
    }
    setState(() => _calculando = true);
    try {

      final exata = await buscarRota(_posicao!, destino);
      final rota = exata ?? rotaEstimada(_posicao!, destino);
      if (!mounted) return;

      setState(() {
        _destinoLL = destino;
        _destinoTexto = texto;
        _rota = rota;
        _valor = _calcularValor(rota.metros / 1000);
      });
      _ajustarCamera([_posicao!, destino, ...rota.pontos]);
      if (exata == null) {
        _aviso(
          'Não consegui traçar a rota pelas ruas ($erroRota). Valor estimado.',
          segundos: 10,
        );
      }
    } catch (e) {
      _aviso('$e');
    } finally {
      if (mounted) setState(() => _calculando = false);
    }
  }

  // Passo 2: confirma o pedido com a forma de pagamento escolhida.
  Future<void> _pedirCorrida() async {
    if (_posicao == null ||
        _destinoLL == null ||
        _rota == null ||
        _valor == null ||
        _pagamento == null) return;
    setState(() => _pedindo = true);
    try {
      final ref = await _db.collection('corridas').add({
        'passageiroId': _uid,
        'motoristaId': null,
        'origem': GeoPoint(_posicao!.latitude, _posicao!.longitude),
        'destino': GeoPoint(_destinoLL!.latitude, _destinoLL!.longitude),
        'destinoTexto': _destinoTexto,
        'distanciaKm': double.parse((_rota!.metros / 1000).toStringAsFixed(2)),
        'valor': _precoDe(categoriaPorId(_categoria)),
        'categoria': _categoria,
        'pagamento': _pagamento,
        'status': 'solicitada',
        'criadoEm': FieldValue.serverTimestamp(),
      });
      _limparAcompanhamento();
      setState(() => _corridaId = ref.id);
      _ouvirCorrida(ref.id);
    } catch (e) {
      _aviso('Não foi possível pedir a corrida: $e', segundos: 10);
    } finally {
      if (mounted) setState(() => _pedindo = false);
    }
  }

  // ---------- Despacho: motorista mais perto primeiro ----------
  // Enquanto a corrida está "solicitada", o app do passageiro oferece o
  // pedido ao motorista mais perto. Ele tem 20 s para aceitar; se recusar
  // ou não responder, passa para o próximo mais perto. Se ninguém mais
  // estiver perto (ou todos recusaram), oferece de novo ao mais perto.
  // Motoristas terminando uma corrida perto daqui também entram na fila
  // (contando a distância que ainda falta para eles ficarem livres).

  /// 20 s na tela do motorista + folga da internet.
  static const _tempoOferta = Duration(seconds: 24);
  Map<String, dynamic>? _dadosCorrida;
  Timer? _despachante;
  String? _rodadaLocal;
  DateTime? _ofertadoDesde;
  bool _despachando = false;

  void _ligarDespacho(bool ligar) {
    _despachante?.cancel();
    _despachante = null;
    if (ligar) {
      _despachar();
      _despachante =
          Timer.periodic(const Duration(seconds: 2), (_) => _despachar());
    }
  }

  Future<void> _despachar() async {
    final d = _dadosCorrida;
    final id = _corridaId;
    if (_despachando || d == null || id == null) return;
    if (d['status'] != 'solicitada') return;
    final atual = d['ofertadoPara'] as String?;
    final recusados = ((d['recusadoPor'] as List?) ?? const [])
        .whereType<String>()
        .toSet();

    // oferta em andamento: espera o tempo dela (contado neste celular)
    if (atual != null) {
      final rodada = '$atual|${d['ofertadoEm']}';
      if (_rodadaLocal != rodada || _ofertadoDesde == null) {
        _rodadaLocal = rodada;
        _ofertadoDesde ??= DateTime.now();
      }
      final passou = DateTime.now().difference(_ofertadoDesde!);
      final aindaOnline = _livres.any((l) => l.id == atual);
      if (passou < _tempoOferta && aindaOnline) return;
      recusados.add(atual); // não respondeu a tempo ou saiu do online
    }

    final origem = _posicao;
    if (origem == null) return;
    // só motoristas que rodam na categoria pedida
    final cat = (d['categoria'] as String?) ?? 'piracar';
    final candidatos =
        _livresAgora.where((l) => l.categorias.contains(cat)).toList();
    var livres = candidatos.where((l) => !recusados.contains(l.id)).toList();
    var recomecar = false;
    if (livres.isEmpty && candidatos.isNotEmpty) {
      // ninguém mais por perto ou todos recusaram: volta ao mais perto
      livres = candidatos.toList();
      recomecar = true;
    }
    if (livres.isEmpty) {
      // nenhum motorista online agora: tira a oferta vencida e espera
      if (atual != null) await _ofertar(id, null, recusados, false);
      return;
    }
    double dist(_Livre l) {
      if (l.quaseLivre && l.livreEm != null) {
        // ainda vai deixar o passageiro dele: conta o que falta + 1 km
        return l.restante +
            1000 +
            Geolocator.distanceBetween(origem.latitude, origem.longitude,
                l.livreEm!.latitude, l.livreEm!.longitude);
      }
      return Geolocator.distanceBetween(origem.latitude, origem.longitude,
          l.pos.latitude, l.pos.longitude);
    }

    livres.sort((a, b) => dist(a).compareTo(dist(b)));
    await _ofertar(id, livres.first.id, recusados, recomecar);
  }

  Future<void> _ofertar(String id, String? motorista, Set<String> recusados,
      bool recomecar) async {
    _despachando = true;
    try {
      await _db.collection('corridas').doc(id).update({
        'ofertadoPara': motorista,
        'ofertadoEm': FieldValue.serverTimestamp(),
        'recusadoPor': recomecar ? <String>[] : recusados.toList(),
      });
      _rodadaLocal = null;
      _ofertadoDesde = DateTime.now();
    } catch (_) {
    } finally {
      _despachando = false;
    }
  }

  void _ligarRadar(bool ligar) {
    if (!ligar) {
      _radarTimer?.cancel();
      _radarTimer = null;
      return;
    }
    if (_radarTimer != null) return;
    _radarTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      _radar.value = (_radar.value + 0.05) % 1.0;
    });
  }

  void _limparAcompanhamento() {
    _ligarRadar(false);
    _ligarDespacho(false);
    _dadosCorrida = null;
    _rodadaLocal = null;
    _ofertadoDesde = null;
    _subCorrida?.cancel();
    _subCorrida = null;
    _status = null;
    _motorista = null;
    _rotaMotorista = null;
    _rotaOrigem = null;
    _rotaTentativa = DateTime.fromMillisecondsSinceEpoch(0);
  }

  // Fica ouvindo a corrida: status e posição do motorista.
  void _ouvirCorrida(String id) {
    _subCorrida = _db.collection('corridas').doc(id).snapshots().listen((doc) {
      final d = doc.data();
      if (d == null || !mounted) return;
      final status = d['status'] as String;
      _dadosCorrida = d;
      if (status == 'solicitada') {
        if (_despachante == null) _ligarDespacho(true);
      } else if (_despachante != null) {
        _ligarDespacho(false);
      }
      final gp = d['motoristaPos'];
      final pos = gp is GeoPoint ? LatLng(gp.latitude, gp.longitude) : null;
      final anterior = _status;
      _ligarRadar(status == 'solicitada');
      setState(() {
        _status = status;
        _motorista = pos;
        final dir = d['motoristaDir'];
        if (dir is num) _motoristaDir = dir.toDouble();
        if (status != 'aceita') _rotaMotorista = null;
      });
      if (status == 'aceita' && pos != null) {
        _atualizarRotaMotorista(pos);
      }
      if (status == 'em_andamento' &&
          anterior != 'em_andamento' &&
          _rota != null) {
        _ajustarCamera(_rota!.pontos);
      }
      if (status == 'finalizada' &&
          anterior != null &&
          anterior != 'finalizada' &&
          d['avaliacaoMotorista'] == null) {
        _avaliarMotorista(id);
      }
    });
  }

  // Ao fim da corrida, o passageiro dá de 1 a 5 estrelas ao motorista.
  // A nota fica na corrida e aparece no perfil do motorista no admin.
  Future<void> _avaliarMotorista(String corridaId) async {
    final nota = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _AvaliacaoDialog(),
    );
    if (nota == null) return;
    try {
      await _db.collection('corridas').doc(corridaId).update({
        'avaliacaoMotorista': nota,
        'motoristaAvaliadoEm': FieldValue.serverTimestamp(),
      });
      _aviso('Obrigado pela avaliação!');
    } catch (e) {
      _aviso('Não foi possível salvar a avaliação: $e');
    }
  }

  // Rota do motorista até o passageiro. Recalcula só se o motorista andou
  // mais de 200 m, e no máximo a cada 10 segundos.
  Future<void> _atualizarRotaMotorista(LatLng pos) async {
    if (_buscandoRota || _posicao == null) return;
    final agora = DateTime.now();
    if (agora.difference(_rotaTentativa).inSeconds < 10) return;
    final longe = _rotaOrigem == null ||
        Geolocator.distanceBetween(_rotaOrigem!.latitude,
                _rotaOrigem!.longitude, pos.latitude, pos.longitude) >
            200;
    if (_rotaMotorista != null && !longe) return;
    _rotaTentativa = agora;
    _buscandoRota = true;
    final exata = await buscarRota(pos, _posicao!);
    _buscandoRota = false;
    if (!mounted || _status != 'aceita') return;
    final rota = exata ?? rotaEstimada(pos, _posicao!);
    final primeira = _rotaMotorista == null;
    _rotaOrigem = pos;
    setState(() => _rotaMotorista = rota);
    if (primeira) _ajustarCamera([pos, _posicao!, ...rota.pontos]);
  }

  // Tira o destino e a rota do mapa e volta a câmera para a pessoa.
  void _limparDestino() {
    setState(() {
      _rota = null;
      _destinoLL = null;
      _valor = null;
    });
    if (_posicao != null) {
      _mapa?.animateCamera(CameraUpdate.newLatLngZoom(_posicao!, 17));
    }
  }

  void _alterarDestino() {
    _fecharBusca();
    _limparDestino();
  }

  Future<void> _cancelar() async {
    await _db
        .collection('corridas')
        .doc(_corridaId)
        .update({'status': 'cancelada'});
  }

  void _novaCorrida() {
    _destino.clear();
    _limparAcompanhamento();
    _corridaId = null;
    _limparDestino();
  }

  bool get _procurando => _corridaId != null && _status == 'solicitada';

  @override
  Widget build(BuildContext context) {
    final emCorrida = _status == 'aceita' || _status == 'em_andamento';
    final livres = emCorrida ? const <_Livre>[] : _livresNoMapa;
    final mostrarRotaMotorista = _status == 'aceita' &&
        _rotaMotorista != null &&
        !_rotaMotorista!.estimada;
    final altura = MediaQuery.sizeOf(context).height;
    final buscando = _corridaId == null && _rota == null && _buscaAberta;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      drawer: const MenuLateral(),
      body: Stack(
        children: [
          ValueListenableBuilder<double>(
            valueListenable: _radar,
            builder: (context, t, _) => GoogleMap(
            style: estiloMapa,
            initialCameraPosition:
                const CameraPosition(target: _centroPirapora, zoom: 15),
            myLocationEnabled: _posicao != null,
            myLocationButtonEnabled: false,
            mapToolbarEnabled: false,
            padding: EdgeInsets.only(
                top: 90, bottom: _rota != null ? 340 : 230),
            circles: {
              if (_status == 'solicitada' && _posicao != null)
                for (final fase in [0.0, 0.5])
                  Circle(
                    circleId: CircleId('radar_$fase'),
                    center: _posicao!,
                    radius: 40 + 360 * ((t + fase) % 1.0),
                    strokeWidth: 2,
                    strokeColor: const Color(0xFF2563EB)
                        .withOpacity(0.7 * (1 - ((t + fase) % 1.0))),
                    fillColor: const Color(0xFF2563EB)
                        .withOpacity(0.25 * (1 - ((t + fase) % 1.0))),
                  ),
            },
            polylines: {
              if (mostrarRotaMotorista)
                Polyline(
                  polylineId: const PolylineId('motorista'),
                  points: _rotaMotorista!.pontos,
                  width: 6,
                  color: Colors.green,
                )
              else if (_rota != null && !_rota!.estimada && _status != 'aceita')
                Polyline(
                  polylineId: const PolylineId('rota'),
                  points: _rota!.pontos,
                  width: 6,
                  color: Colors.blue,
                ),
            },
            markers: {
              if (_destinoLL != null)
                Marker(
                  markerId: const MarkerId('destino'),
                  position: _destinoLL!,
                  infoWindow: InfoWindow(title: _destinoTexto),
                ),
              for (final l in livres)
                Marker(
                  markerId: MarkerId('livre_${l.id}'),
                  position: l.pos,
                  icon: _iconeCarroCima ?? _iconeCarro,
                  flat: true,
                  rotation: l.direcao,
                  anchor: const Offset(0.5, 0.5),
                  zIndex: 1,
                  infoWindow: const InfoWindow(title: 'Motorista disponível'),
                ),
              if (_motorista != null && emCorrida)
                Marker(
                  markerId: const MarkerId('motorista'),
                  position: _motorista!,
                  icon: _iconeCarroCima ?? _iconeCarro,
                  flat: true,
                  rotation: _motoristaDir,
                  anchor: const Offset(0.5, 0.5),
                  zIndex: 3,
                  infoWindow: const InfoWindow(title: 'Motorista'),
                ),
            },
            onMapCreated: (c) => _mapa = c,
          ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Column(
                children: [
                  const _BarraTopo(),
                  if (!buscando)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: AvisoBanner(tipo: 'passageiro'),
                    ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_corridaId != null &&
                    chatAberto(_status) &&
                    _dadosCorrida?['motoristaId'] is String)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 16, 12),
                    child: BolinhaChat(
                      corridaId: _corridaId!,
                      souMotorista: false,
                      outroId: _dadosCorrida?['motoristaId'] as String?,
                    ),
                  ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: double.infinity,
                  constraints: BoxConstraints(
                      maxHeight: buscando ? altura * 0.78 : altura * 0.6),
                  decoration: BoxDecoration(
                    color: _procurando ? null : sup(Colors.white),
                    gradient: _procurando
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF14213D), Color(0xFF1F3563)])
                        : null,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
                    boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 14)],
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                            child: _corridaId != null
                                ? SingleChildScrollView(child: _painelCorrida())
                                : (_rota != null
                                    ? SingleChildScrollView(child: _resumo())
                                    : _buscaDestino(livres.length)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Hospitais de Pirapora, para emergência: toca e já vai para o destino.
  static const _listaHospitais = [
    (
      nome: 'Fundação Hospitalar Dr. Moisés Magalhães Freire',
      endereco: 'R. Montes Claros, 1237 · Santo Antônio',
      local: LatLng(-17.3383174, -44.9395277),
    ),
    (
      nome: 'Hospital Unimed Pirapora',
      endereco: 'Av. João Cota Sobrinho, 627 · Industrial',
      local: LatLng(-17.3306624, -44.9406352),
    ),
  ];

  Future<void> _irParaHospital(String nome, LatLng local) async {
    setState(() => _hospitais = false);
    _destino.text = nome;
    await _calcularPara(local, nome);
  }

  Widget _painelHospitais() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Voltar',
              icon: Icon(Icons.arrow_back_ios_new_rounded,
                  size: 20, color: tx(azulNoite)),
              onPressed: () => setState(() => _hospitais = false),
            ),
            Text('Hospitais',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: tx(azulNoite),
                    letterSpacing: -0.3)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 48, bottom: 4),
          child: Text('Toque no hospital para ir direto',
              style: TextStyle(fontSize: 13, color: fr(Colors.black54))),
        ),
        if (_calculando)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(),
          ),
        for (final h in _listaHospitais)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Material(
              color: fu(const Color(0xFFF4F6FA)),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _irParaHospital(h.nome, h.local),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: const BoxDecoration(
                            color: Color(0xFFFDECEC), shape: BoxShape.circle),
                        alignment: Alignment.center,
                        child: const Text('🏥', style: TextStyle(fontSize: 22)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(h.nome,
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: tx(azulNoite))),
                            const SizedBox(height: 3),
                            Text(h.endereco,
                                style: TextStyle(
                                    fontSize: 13, color: fr(Colors.black54))),
                            const SizedBox(height: 3),
                            const Text('Aberto 24 horas',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF2E7D32))),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: tx(azulNoite)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buscaDestino(int motoristas) {
    if (_hospitais) return _painelHospitais();
    final aberta = _buscaAberta;
    final borda = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: azulNoite, width: 2),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Para onde vamos?',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: tx(azulNoite),
                letterSpacing: -0.3)),
        const SizedBox(height: 10),
        TextField(
          controller: _destino,
          focusNode: _focoBusca,
          onTap: () => setState(() {}),
          onChanged: _digitou,
          onSubmitted: (_) => _calcular(),
          textInputAction: TextInputAction.search,
          textCapitalization: TextCapitalization.words,
          style: const TextStyle(fontSize: 17),
          decoration: InputDecoration(
            hintText: 'Buscar destino',
            prefixIcon: Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                    color: azulNoite, shape: BoxShape.circle),
                child: const Icon(Icons.circle, size: 8, color: amarelo),
              ),
            ),
            suffixIcon: aberta
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _fecharBusca,
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(vertical: 18),
            filled: true,
            fillColor: sup(Colors.white),
            enabledBorder: borda,
            border: borda,
            focusedBorder: borda.copyWith(
                borderSide: const BorderSide(color: Color(0xFF1E88E5), width: 2)),
          ),
        ),
        if (_calculando)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: LinearProgressIndicator(),
          ),
        if (!aberta) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Atalho('🚌', 'Rodoviária', () => _atalho('Rodoviária de Pirapora')),
              _Atalho('🏥', 'Hospital', () => setState(() => _hospitais = true)),
              _Atalho('🛒', 'Centro', () => _atalho('Centro, Pirapora')),
            ],
          ),
          if (motoristas > 0) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.circle,
                  size: 10,
                  color: motoristas > 0 ? const Color(0xFF2E7D32) : Colors.black26),
              const SizedBox(width: 6),
              Text(
                _posicao == null
                    ? 'Pegando sua localização...'
                    : motoristas == 0
                        ? 'Nenhum motorista perto agora'
                        : '$motoristas ${motoristas == 1 ? 'motorista' : 'motoristas'} perto de você',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: motoristas > 0
                        ? const Color(0xFF2E7D32)
                        : fr(Colors.black54)),
              ),
            ],
          ),
          ],
        ] else
          Flexible(child: _listaSugestoes()),
      ],
    );
  }

  Widget _listaSugestoes() {
    final texto = _destino.text.trim();
    if (texto.length < 3) {
      return Padding(
        padding: EdgeInsets.only(top: 18),
        child: Text('Digite pelo menos 3 letras do endereço.',
            style: TextStyle(color: fr(Colors.black54))),
      );
    }
    if (_buscandoSug && _sugestoes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 18),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_sugestoes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Text('Nada encontrado para "$texto". Tente outro endereço.',
            style: TextStyle(color: fr(Colors.black54))),
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 6),
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
          child: Text('SUGESTÕES',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: fr(Colors.black54))),
        ),
        for (final s in _sugestoes) _itemSugestao(s),
      ],
    );
  }

  Widget _itemSugestao(Sugestao s) {
    final n = s.destaque.clamp(0, s.principal.length);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _calculando ? null : () => _escolher(s),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: ln(Color(0xFFEEF0F3)))),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: fu(Color(0xFFEEF2F7)), shape: BoxShape.circle),
              child: const Icon(Icons.place, color: Color(0xFFE53935), size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: s.principal.substring(0, n),
                          style: const TextStyle(color: Color(0xFF1565C0))),
                      TextSpan(text: s.principal.substring(n)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  if (s.secundario.isNotEmpty)
                    Text(s.secundario,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: fr(Colors.black54))),
                ],
              ),
            ),
            if (s.metros != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                    '${(s.metros! / 1000).toStringAsFixed(1).replaceAll('.', ',')} km',
                    style:
                        TextStyle(fontSize: 12, color: fr(Colors.black54))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _resumo() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Destino: $_destinoTexto',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(_rota!.resumo),
        const SizedBox(height: 12),
        const Text('Escolha a categoria',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        for (final c in _categoriasVisiveis)
          CartaoCategoria(
            categoria: c,
            selecionado: _categoria == c.id,
            onTap: () => setState(() => _categoria = c.id),
            direita: Text(formatarReal(_precoDe(c)),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w900)),
          ),
        const SizedBox(height: 8),
        Text('PAGAMENTO',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: fr(Color(0xFF64748B)))),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final e in _formas.entries) ...[
              if (e.key != _formas.keys.first) const SizedBox(width: 8),
              Expanded(child: _botaoPagamento(e.key, e.value)),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: Text('Você paga direto ao motorista no fim da corrida',
              style: TextStyle(fontSize: 12, color: fr(Color(0xFF94A3B8)))),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            SizedBox(
              width: 60,
              height: 60,
              child: OutlinedButton(
                onPressed: _alterarDestino,
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  side: BorderSide(color: ln(Color(0xFFE2E8F0)), width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
                child: Tooltip(
                  message: 'Alterar destino',
                  child: Icon(Icons.edit_location_alt_outlined,
                      color: tx(Color(0xFF334155))),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 60,
                child: FilledButton(
                  onPressed:
                      _pedindo || _pagamento == null ? null : _pedirCorrida,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1565C0),
                    disabledBackgroundColor: const Color(0xFFE2E8F0),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    textStyle: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(_pagamento == null
                        ? 'Escolha o pagamento'
                        : 'Confirmar ${categoriaPorId(_categoria).nome} · '
                            '${formatarReal(_precoDe(categoriaPorId(_categoria)))}'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _botaoPagamento(String id, String nome) {
    final sel = _pagamento == id;
    return Material(
      color: sel ? const Color(0xFF0F172A) : sup(Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
            color: sel ? const Color(0xFF0F172A) : ln(Color(0xFFE2E8F0)),
            width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _pagamento = id),
        child: SizedBox(
          height: 64,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_icones[id],
                  size: 22,
                  color: sel
                      ? (id == 'pix'
                          ? const Color(0xFF5EEAD4)
                          : Colors.white)
                      : fr(Color(0xFF475569))),
              const SizedBox(height: 4),
              Text(nome,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.w600,
                      color: sel ? Colors.white : tx(Color(0xFF334155)))),
            ],
          ),
        ),
      ),
    );
  }

  // Painel azul-escuro mostrado enquanto procura motorista.
  Widget _painelBuscando(
      Map<String, dynamic> dados, double? valor, String? forma) {
    const amarelo = Color(0xFFFFD23F);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('BUSCANDO',
                      style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 1.6,
                          fontWeight: FontWeight.w800,
                          color: amarelo)),
                  SizedBox(height: 4),
                  Text('Procurando motorista',
                      style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ],
              ),
            ),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: amarelo,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: amarelo.withOpacity(0.25), spreadRadius: 8)
                ],
              ),
              child: const Icon(Icons.directions_car_filled,
                  size: 34, color: Color(0xFF14213D)),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const _EtapasBusca(),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Destino',
                      style: TextStyle(fontSize: 12, color: Color(0xFFAAB8D6))),
                  const SizedBox(height: 2),
                  Text('${dados['destinoTexto'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ],
              ),
            ),
            if (valor != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(forma ?? '',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFFAAB8D6))),
                  Text(formatarReal(valor),
                      style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: amarelo)),
                ],
              ),
          ],
        ),
        const SizedBox(height: 18),
        TextButton(
          onPressed: _cancelar,
          style: TextButton.styleFrom(
            backgroundColor: Colors.white.withOpacity(0.12),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: const StadiumBorder(),
          ),
          child: const Text('Cancelar corrida',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ),
      ],
    );
  }

  Widget _painelCorrida() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _db.collection('corridas').doc(_corridaId).snapshots(),
      builder: (context, snap) {
        final dados = snap.data?.data();
        if (dados == null) return const LinearProgressIndicator();
        final status = dados['status'] as String;
        final encerrada = status == 'finalizada' || status == 'cancelada';
        final valor = (dados['valor'] as num?)?.toDouble();
        final forma = _nomesPagamento[dados['pagamento']];
        if (status == 'solicitada') {
          return _painelBuscando(dados, valor, forma);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((status == 'aceita' || status == 'em_andamento') &&
                dados['motoristaId'] is String)
              _CartaoMotorista(uid: dados['motoristaId'] as String),
            Text(_statusTexto[status] ?? status,
                style: Theme.of(context).textTheme.titleMedium),
            if (status == 'aceita' && dados['naFila'] == true)
              const Text(
                  'O motorista está terminando outra corrida aqui perto '
                  'e vem buscar você em seguida.',
                  textAlign: TextAlign.center)
            else if (status == 'aceita')
              Text(_rotaMotorista != null
                  ? 'Motorista a ${_rotaMotorista!.resumo}'
                  : 'Localizando o motorista...'),
            const SizedBox(height: 4),
            Text('Destino: ${dados['destinoTexto']}'),
            if (valor != null)
              Text('${formatarReal(valor)}${forma != null ? ' • $forma' : ''}'),
            const SizedBox(height: 12),
            if (encerrada)
              FilledButton(
                  onPressed: _novaCorrida, child: const Text('Nova corrida'))
            else if (status == 'solicitada' || status == 'aceita')
              OutlinedButton(
                  onPressed: _cancelar, child: const Text('Cancelar corrida')),
          ],
        );
      },
    );
  }
}

class _AvaliacaoDialog extends StatefulWidget {
  const _AvaliacaoDialog();

  @override
  State<_AvaliacaoDialog> createState() => _AvaliacaoDialogState();
}

class _AvaliacaoDialogState extends State<_AvaliacaoDialog> {
  int _nota = 0;

  static const _legendas = [
    '', 'Muito ruim', 'Ruim', 'Regular', 'Bom', 'Excelente'
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Como foi o motorista?', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  tooltip: '$i ${i == 1 ? 'estrela' : 'estrelas'}',
                  iconSize: 38,
                  onPressed: () => setState(() => _nota = i),
                  icon: Icon(
                    i <= _nota
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    color: const Color(0xFFFFB300),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_legendas[_nota],
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Agora não'),
        ),
        FilledButton(
          onPressed: _nota == 0 ? null : () => Navigator.pop(context, _nota),
          child: const Text('Enviar'),
        ),
      ],
    );
  }
}

/// Foto, nome, nota e carro do motorista que aceitou a corrida.
class _CartaoMotorista extends StatelessWidget {
  const _CartaoMotorista({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').doc(uid).snapshots(),
      builder: (context, snap) {
        final m = snap.data?.data();
        if (m == null) return const SizedBox.shrink();
        final nome = (m['nome'] ?? 'Motorista').toString();
        final carro = [m['carro'], m['cor']]
            .map((v) => (v ?? '').toString().trim())
            .where((v) => v.isNotEmpty)
            .join(' • ');
        final placa = (m['placa'] ?? '').toString();
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: fu(Color(0xFFF4F6FA)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              FotoPerfil(dados: m, raio: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nome,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      future: db
                          .collection('corridas')
                          .where('motoristaId', isEqualTo: uid)
                          .get(),
                      builder: (context, s) {
                        final notas = (s.data?.docs ?? const [])
                            .map((d) => d.data()['avaliacaoMotorista'])
                            .whereType<num>()
                            .toList();
                        final media = notas.isEmpty
                            ? null
                            : notas.reduce((a, b) => a + b) / notas.length;
                        return Row(
                          children: [
                            const Icon(Icons.star_rounded,
                                size: 16, color: Color(0xFFFFB300)),
                            const SizedBox(width: 2),
                            Text(
                              media == null
                                  ? 'Novo motorista'
                                  : media
                                      .toStringAsFixed(1)
                                      .replaceAll('.', ','),
                              style: TextStyle(color: fr(Colors.black54)),
                            ),
                          ],
                        );
                      },
                    ),
                    if (carro.isNotEmpty)
                      Text(carro,
                          style: TextStyle(color: fr(Colors.black54))),
                  ],
                ),
              ),
              if (placa.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: sup(Colors.white),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ln(Colors.black26)),
                  ),
                  child: Text(placa.toUpperCase(),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, letterSpacing: 1)),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Só o botão redondo do menu, solto em cima do mapa.
class _BarraTopo extends StatelessWidget {
  const _BarraTopo();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Material(
          color: sup(Colors.white),
          shape: const CircleBorder(),
          elevation: 4,
          shadowColor: Colors.black38,
          child: IconButton(
            tooltip: 'Menu',
            icon: Icon(Icons.menu_rounded, size: 26, color: tx(azulNoite)),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
    );
  }
}

class _Atalho extends StatelessWidget {
  const _Atalho(this.emoji, this.texto, this.onTap);

  final String emoji;
  final String texto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ta(Color(0xFFFFF4D6)),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text('$emoji $texto',
              style: TextStyle(
                  color: tx(azulNoite), fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

/// Quatro traços que vão se enchendo, em repetição, enquanto procura.
class _EtapasBusca extends StatefulWidget {
  const _EtapasBusca();

  @override
  State<_EtapasBusca> createState() => _EtapasBuscaState();
}

class _EtapasBuscaState extends State<_EtapasBusca> {
  Timer? _t;
  int _n = 1;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (mounted) setState(() => _n = _n % 4 + 1);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 5,
              decoration: BoxDecoration(
                color: i < _n
                    ? const Color(0xFFFFD23F)
                    : Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          if (i < 3) const SizedBox(width: 6),
        ],
      ],
    );
  }
}
