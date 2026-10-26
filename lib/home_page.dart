import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'rota.dart';

// Preço: valor fixo até 3 km; depois, valor por km extra (proporcional).
const _valorBase = 10.0;
const _kmIncluidos = 3.0;
const _precoKmExtra = 1.76;

double _calcularValor(double km) {
  if (km <= _kmIncluidos) return _valorBase;
  return double.parse(
      (_valorBase + (km - _kmIncluidos) * _precoKmExtra).toStringAsFixed(2));
}

String _real(double v) => 'R\$ ${v.toStringAsFixed(2).replaceAll('.', ',')}';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _centroPiracicaba = LatLng(-17.3453, -44.9419);

  final _destino = TextEditingController();
  GoogleMapController? _mapa;
  LatLng? _posicao;
  LatLng? _destinoLL;
  String _destinoTexto = '';
  Rota? _rota;
  double? _valor;
  String? _pagamento;
  String? _corridaId;
  bool _calculando = false;
  bool _pedindo = false;

  // Acompanhamento do motorista em tempo real
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subCorrida;
  String? _status;
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

  @override
  void initState() {
    super.initState();
    _localizar();
  }

  @override
  void dispose() {
    _subCorrida?.cancel();
    super.dispose();
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
    _mapa?.animateCamera(CameraUpdate.newLatLngZoom(ll, 15));
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

  // Passo 1: acha o destino, traça a rota e calcula o valor.
  Future<void> _calcular() async {
    if (_posicao == null || _destino.text.trim().isEmpty) return;
    setState(() => _calculando = true);
    try {
      final texto = _destino.text.trim();
      final locs = await locationFromAddress('$texto, Pirapora, MG');
      if (locs.isEmpty) throw 'Endereço não encontrado';
      final destino = LatLng(locs.first.latitude, locs.first.longitude);

      // Tenta a rota exata; se falhar, usa uma distância estimada.
      final exata = await buscarRota(_posicao!, destino);
      final rota = exata ?? rotaEstimada(_posicao!, destino);
      if (!mounted) return;

      setState(() {
        _destinoLL = destino;
        _destinoTexto = texto;
        _rota = rota;
        _valor = _calcularValor(rota.metros / 1000);
      });
      _ajustarCamera(rota.pontos);
      if (exata == null) {
        _aviso(
          'Não consegui a rota exata ($erroRota). Usando distância estimada.',
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
        'valor': _valor,
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

  void _limparAcompanhamento() {
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
      final gp = d['motoristaPos'];
      final pos = gp is GeoPoint ? LatLng(gp.latitude, gp.longitude) : null;
      final anterior = _status;
      setState(() {
        _status = status;
        _motorista = pos;
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
    });
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
    if (primeira) _ajustarCamera(rota.pontos);
  }

  void _alterarDestino() {
    setState(() {
      _rota = null;
      _destinoLL = null;
      _valor = null;
    });
    if (_posicao != null) {
      _mapa?.animateCamera(CameraUpdate.newLatLngZoom(_posicao!, 15));
    }
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
    setState(() {
      _corridaId = null;
      _rota = null;
      _destinoLL = null;
      _valor = null;
    });
    if (_posicao != null) {
      _mapa?.animateCamera(CameraUpdate.newLatLngZoom(_posicao!, 15));
    }
  }

  @override
  Widget build(BuildContext context) {
    final emCorrida = _status == 'aceita' || _status == 'em_andamento';
    return Scaffold(
      appBar: AppBar(
        title: const Text('PiraCar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition:
                const CameraPosition(target: _centroPiracicaba, zoom: 13),
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            padding: EdgeInsets.only(bottom: _rota != null ? 340 : 170),
            polylines: {
              if (_status == 'aceita' && _rotaMotorista != null)
                Polyline(
                  polylineId: const PolylineId('motorista'),
                  points: _rotaMotorista!.pontos,
                  width: 6,
                  color: Colors.green,
                )
              else if (_rota != null)
                Polyline(
                  polylineId: const PolylineId('rota'),
                  points: _rota!.pontos,
                  width: 5,
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
              if (_corridaId != null && _posicao != null)
                Marker(
                  markerId: const MarkerId('origem'),
                  position: _posicao!,
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueAzure),
                  infoWindow: const InfoWindow(title: 'Você'),
                ),
              if (_motorista != null && emCorrida)
                Marker(
                  markerId: const MarkerId('motorista'),
                  position: _motorista!,
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueGreen),
                  infoWindow: const InfoWindow(title: 'Motorista'),
                ),
            },
            onMapCreated: (c) => _mapa = c,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _corridaId != null
                    ? _painelCorrida()
                    : (_rota != null ? _resumo() : _formDestino()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _formDestino() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _destino,
          decoration: const InputDecoration(
            labelText: 'Para onde vamos?',
            prefixIcon: Icon(Icons.place),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _calculando || _posicao == null ? null : _calcular,
            child: Text(_posicao == null
                ? 'Obtendo localização...'
                : (_calculando ? 'Calculando...' : 'Ver valor da corrida')),
          ),
        ),
      ],
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
        const SizedBox(height: 4),
        Text(
          'Valor: ${_real(_valor!)}',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        Text(
          'Até 3 km: ${_real(_valorBase)} • depois ${_real(_precoKmExtra)} por km',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 10),
        const Text('Forma de pagamento'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final e in _formas.entries)
              ChoiceChip(
                avatar: Icon(_icones[e.key], size: 18),
                label: Text(e.value),
                selected: _pagamento == e.key,
                onSelected: (_) => setState(() => _pagamento = e.key),
              ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'O pagamento é feito direto ao motorista no fim da corrida.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _pedindo || _pagamento == null ? null : _pedirCorrida,
            child: Text(_pagamento == null
                ? 'Escolha a forma de pagamento'
                : 'Pedir corrida'),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: _alterarDestino,
            child: const Text('Alterar destino'),
          ),
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
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_statusTexto[status] ?? status,
                style: Theme.of(context).textTheme.titleMedium),
            if (status == 'aceita')
              Text(_rotaMotorista != null
                  ? 'Motorista a ${_rotaMotorista!.resumo}'
                  : 'Localizando o motorista...'),
            const SizedBox(height: 4),
            Text('Destino: ${dados['destinoTexto']}'),
            if (valor != null)
              Text('${_real(valor)}${forma != null ? ' • $forma' : ''}'),
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
