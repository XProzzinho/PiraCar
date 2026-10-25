import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _centroPiracicaba = LatLng(-22.7253, -47.6492);

  final _destino = TextEditingController();
  GoogleMapController? _mapa;
  LatLng? _posicao;
  String? _corridaId;
  bool _pedindo = false;

  final _db = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser!.uid;

  static const _statusTexto = {
    'solicitada': 'Procurando motorista...',
    'aceita': 'Motorista a caminho',
    'em_andamento': 'Corrida em andamento',
    'finalizada': 'Corrida finalizada',
    'cancelada': 'Corrida cancelada',
  };

  @override
  void initState() {
    super.initState();
    _localizar();
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

  Future<void> _pedirCorrida() async {
    if (_posicao == null || _destino.text.trim().isEmpty) return;
    setState(() => _pedindo = true);
    try {
      final locs = await locationFromAddress(_destino.text.trim());
      if (locs.isEmpty) throw 'Endereço não encontrado';
      final d = locs.first;
      final ref = await _db.collection('corridas').add({
        'passageiroId': _uid,
        'motoristaId': null,
        'origem': GeoPoint(_posicao!.latitude, _posicao!.longitude),
        'destino': GeoPoint(d.latitude, d.longitude),
        'destinoTexto': _destino.text.trim(),
        'status': 'solicitada',
        'criadoEm': FieldValue.serverTimestamp(),
      });
      setState(() => _corridaId = ref.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _pedindo = false);
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
    setState(() => _corridaId = null);
  }

  @override
  Widget build(BuildContext context) {
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
            onMapCreated: (c) => _mapa = c,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _corridaId == null ? _formPedido() : _painelCorrida(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _formPedido() {
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
            onPressed: _pedindo || _posicao == null ? null : _pedirCorrida,
            child: Text(_posicao == null
                ? 'Obtendo localização...'
                : 'Pedir corrida'),
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
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_statusTexto[status] ?? status,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Destino: ${dados['destinoTexto']}'),
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
