import 'dart:convert';

import 'package:geocoding/geocoding.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

const _chave = String.fromEnvironment('MAPS_KEY');
const _pirapora = LatLng(-17.3453, -44.9419);

/// Uma sugestão de endereço enquanto a pessoa digita.
class Sugestao {
  final String? placeId; // Google Places
  final String principal; // ex.: "Rua São Paulo"
  final String secundario; // ex.: "Centro, Pirapora - MG"
  final int destaque; // quantas letras do início batem com o digitado
  final int? metros;
  final LatLng? local; // já resolvido (busca alternativa)

  Sugestao({
    this.placeId,
    required this.principal,
    required this.secundario,
    this.destaque = 0,
    this.metros,
    this.local,
  });
}

/// Motivo da última falha das sugestões do Google (para diagnóstico).
String erroLugares = '';

/// Sugestões do Google Places (perto de Pirapora). Se o Google falhar
/// (por exemplo, Places API desligada), usa a busca simples de endereço.
Future<List<Sugestao>> buscarSugestoes(String texto, LatLng? perto) async {
  texto = texto.trim();
  if (texto.length < 3) return [];
  final google = await _googleAutocomplete(texto, perto);
  if (google != null) return google;
  return _buscaSimples(texto);
}

Future<List<Sugestao>?> _googleAutocomplete(String texto, LatLng? perto) async {
  if (_chave.isEmpty) {
    erroLugares = 'sem chave';
    return null;
  }
  final centro = perto ?? _pirapora;
  try {
    final resp = await http
        .post(
          Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': _chave,
          },
          body: jsonEncode({
            'input': texto,
            'languageCode': 'pt-BR',
            'includedRegionCodes': ['br'],
            'locationBias': {
              'circle': {
                'center': {
                  'latitude': _pirapora.latitude,
                  'longitude': _pirapora.longitude,
                },
                'radius': 20000.0,
              }
            },
            'origin': {
              'latitude': centro.latitude,
              'longitude': centro.longitude,
            },
          }),
        )
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      erroLugares = 'Google ${resp.statusCode}';
      return null;
    }
    final lista = (jsonDecode(resp.body)['suggestions'] as List?) ?? [];
    final saida = <Sugestao>[];
    for (final s in lista) {
      final p = s['placePrediction'];
      if (p == null) continue;
      final fmt = p['structuredFormat'] ?? {};
      final main = (fmt['mainText']?['text'] ?? p['text']?['text'] ?? '')
          .toString();
      final matches = (fmt['mainText']?['matches'] as List?) ?? const [];
      final fim = matches.isNotEmpty && matches.first['startOffset'] == null
          ? (matches.first['endOffset'] as num?)?.toInt() ?? 0
          : 0;
      saida.add(Sugestao(
        placeId: p['placeId']?.toString(),
        principal: main,
        secundario: (fmt['secondaryText']?['text'] ?? '').toString(),
        destaque: fim.clamp(0, main.length),
        metros: (p['distanceMeters'] as num?)?.toInt(),
      ));
    }
    erroLugares = '';
    return saida;
  } catch (e) {
    erroLugares = 'Google: $e';
    return null;
  }
}

Future<List<Sugestao>> _buscaSimples(String texto) async {
  try {
    final locs = await locationFromAddress('$texto, Pirapora, MG');
    if (locs.isEmpty) return [];
    final l = locs.first;
    return [
      Sugestao(
        principal: texto,
        secundario: 'Pirapora - MG',
        destaque: texto.length,
        local: LatLng(l.latitude, l.longitude),
      ),
    ];
  } catch (_) {
    return [];
  }
}

/// Pega a posição de uma sugestão escolhida.
Future<LatLng?> localDaSugestao(Sugestao s) async {
  if (s.local != null) return s.local;
  if (s.placeId == null || _chave.isEmpty) return null;
  try {
    final resp = await http.get(
      Uri.parse('https://places.googleapis.com/v1/places/${s.placeId}'),
      headers: {
        'X-Goog-Api-Key': _chave,
        'X-Goog-FieldMask': 'location',
      },
    ).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final loc = jsonDecode(resp.body)['location'];
    if (loc == null) return null;
    return LatLng((loc['latitude'] as num).toDouble(),
        (loc['longitude'] as num).toDouble());
  } catch (_) {
    return null;
  }
}
