import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'excluir_conta.dart';
import 'foto.dart';
import 'foto_trocar.dart';
import 'menu_lateral.dart';
import 'menu_visual.dart';
import 'cores.dart';

const _fundo = Color(0xFFF4F6FA);

String _data(dynamic ts) {
  if (ts is! Timestamp) return '';
  final d = ts.toDate();
  String dois(int n) => n.toString().padLeft(2, '0');
  return '${dois(d.day)}/${dois(d.month)}/${d.year} às ${dois(d.hour)}:${dois(d.minute)}';
}

// ---------- Minhas viagens ----------

class MinhasViagensPage extends StatelessWidget {
  const MinhasViagensPage({super.key});

  static const _status = {
    'solicitada': ('Procurando motorista', Colors.orange),
    'aceita': ('Motorista a caminho', Colors.blue),
    'em_andamento': ('Em viagem', Colors.indigo),
    'finalizada': ('Finalizada', Color(0xFF2E7D32)),
    'cancelada': ('Cancelada', Colors.red),
  };

  static const _pagamento = {
    'credito': 'Crédito',
    'debito': 'Débito',
    'pix': 'Pix',
  };

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return Scaffold(
      backgroundColor: _fundo,
      appBar: barraTela('Minhas viagens'),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('corridas')
            .where('passageiroId', isEqualTo: uid)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Erro: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs.toList()
            ..sort((a, b) {
              final ta = a.data()['criadoEm'], tb = b.data()['criadoEm'];
              if (ta is! Timestamp) return -1;
              if (tb is! Timestamp) return 1;
              return tb.compareTo(ta);
            });
          if (docs.isEmpty) {
            return Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Você ainda não fez nenhuma viagem.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: fr(Colors.black54), fontSize: 16)),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(14),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final c = docs[i].data();
              final st = _status[c['status']] ?? ('-', Colors.grey);
              final valor = c['valor'];
              final km = c['distanciaKm'];
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: sup(Colors.white),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.place, color: tx(corMenuTitulo)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            (c['destinoTexto'] ?? 'Destino').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: tx(corMenuTitulo)),
                          ),
                        ),
                        if (valor is num)
                          Text(formatarReal(valor),
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: tx(corMenuTitulo))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        _data(c['criadoEm']),
                        if (km is num)
                          '${km.toStringAsFixed(1).replaceAll('.', ',')} km',
                        if (_pagamento[c['pagamento']] != null)
                          _pagamento[c['pagamento']]!,
                      ].where((s) => s.isNotEmpty).join(' • '),
                      style: const TextStyle(color: corMenuTexto),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: st.$2.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(st.$1,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: st.$2)),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------- Adicionar cupom ----------

class CupomPage extends StatefulWidget {
  const CupomPage({super.key});

  @override
  State<CupomPage> createState() => _CupomPageState();
}

class _CupomPageState extends State<CupomPage> {
  final _codigo = TextEditingController();
  bool _verificando = false;

  @override
  void dispose() {
    _codigo.dispose();
    super.dispose();
  }

  void _aviso(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _adicionar() async {
    final codigo = _codigo.text.trim().toUpperCase();
    if (codigo.isEmpty) return;
    setState(() => _verificando = true);
    try {
      final db = FirebaseFirestore.instance;
      final achou = await db
          .collection('cupons')
          .where('codigo', isEqualTo: codigo)
          .limit(1)
          .get();
      if (achou.docs.isEmpty || achou.docs.first.data()['ativo'] == false) {
        _aviso('Cupom inválido ou vencido.');
        return;
      }
      await db
          .collection('users')
          .doc(FirebaseAuth.instance.currentUser!.uid)
          .update({
        'cupons': FieldValue.arrayUnion([codigo])
      });
      _codigo.clear();
      _aviso('Cupom $codigo adicionado!');
    } catch (e) {
      _aviso('Não foi possível verificar o cupom: $e');
    } finally {
      if (mounted) setState(() => _verificando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return Scaffold(
      backgroundColor: _fundo,
      appBar: barraTela('Adicionar cupom'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Digite o código do cupom',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: tx(corMenuTitulo))),
          const SizedBox(height: 12),
          TextField(
            controller: _codigo,
            textCapitalization: TextCapitalization.characters,
            onSubmitted: (_) => _adicionar(),
            decoration: InputDecoration(
              hintText: 'EX: PIRACAR10',
              prefixIcon: const Icon(Icons.confirmation_number_outlined),
              filled: true,
              fillColor: sup(Colors.white),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: corMenuTitulo, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 54,
            child: FilledButton(
              onPressed: _verificando ? null : _adicionar,
              style: FilledButton.styleFrom(
                backgroundColor: corMenuTitulo,
                shape: const StadiumBorder(),
              ),
              child: Text(_verificando ? 'Verificando...' : 'Adicionar'),
            ),
          ),
          const SizedBox(height: 28),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .snapshots(),
            builder: (context, snap) {
              final lista = (snap.data?.data()?['cupons'] as List?)
                      ?.map((e) => e.toString())
                      .toList() ??
                  const <String>[];
              if (lista.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Meus cupons',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, color: corMenuTexto)),
                  const SizedBox(height: 8),
                  for (final c in lista)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: ta(Color(0xFFFFF4D6)),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.local_offer_outlined,
                              color: tx(corMenuTitulo)),
                          const SizedBox(width: 10),
                          Text(c,
                              style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: tx(corMenuTitulo))),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ---------- Divulgação ----------

class DivulgacaoPage extends StatelessWidget {
  const DivulgacaoPage({super.key});

  static const mensagem =
      'Conheça o Bora Car, o app de corridas de Pirapora! '
      'Peça seu carro pelo celular, acompanhe o motorista no mapa e '
      'pague com cartão ou Pix.';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _fundo,
      appBar: barraTela('Divulgação'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: corMenuTitulo,
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.campaign_outlined, color: corMenuAmarelo, size: 34),
                SizedBox(height: 10),
                Text('Ajude o Bora Car a crescer',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800)),
                SizedBox(height: 6),
                Text(
                  'Copie a mensagem abaixo e mande para os amigos, '
                  'nos grupos e no status.',
                  style: TextStyle(color: Color(0xFFC9D6EA)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: sup(Colors.white),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(mensagem,
                style: TextStyle(fontSize: 16, color: tx(corMenuTitulo))),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 54,
            child: FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(const ClipboardData(text: mensagem));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Mensagem copiada! É só colar e enviar.')));
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: corMenuTitulo,
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.copy, color: corMenuAmarelo),
              label: const Text('Copiar mensagem'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Ajuda ----------

class AjudaPage extends StatelessWidget {
  const AjudaPage({super.key, required this.abrirChat});

  final VoidCallback abrirChat;

  static const _perguntas = [
    (
      'Quanto custa a corrida?',
      'R\$ 10,00 até 3 km. A partir daí, R\$ 1,76 por quilômetro a mais. '
          'O valor aparece antes de você pedir.'
    ),
    (
      'Como eu pago?',
      'Antes de pedir a corrida, escolha cartão de crédito, débito ou Pix.'
    ),
    (
      'Como sei onde está o motorista?',
      'Depois que ele aceitar, o carrinho aparece no mapa em tempo real, '
          'com o caminho até você.'
    ),
    (
      'Como mudo meus dados ou minha foto?',
      'No menu, toque em Configurações.'
    ),
    (
      'Como apago minha conta?',
      'No menu, toque em Configurações e depois em Excluir minha conta.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _fundo,
      appBar: barraTela('Ajuda'),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          for (final p in _perguntas)
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                shape: const Border(),
                title: Text(p.$1,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: tx(corMenuTitulo))),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.$2, style: const TextStyle(color: corMenuTexto))
                ],
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            height: 54,
            child: FilledButton.icon(
              onPressed: abrirChat,
              style: FilledButton.styleFrom(
                backgroundColor: corMenuTitulo,
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.chat_outlined, color: corMenuAmarelo),
              label: const Text('Não achou? Fale conosco'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Configurações ----------

class ConfiguracoesPage extends StatelessWidget {
  const ConfiguracoesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    return Scaffold(
      backgroundColor: _fundo,
      appBar: barraTela('Configurações'),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots(),
        builder: (context, snap) {
          final p = snap.data?.data() ?? const <String, dynamic>{};
          final nome = (p['nome'] as String?)?.trim().isNotEmpty == true
              ? p['nome'] as String
              : (user.displayName ?? '');
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 32),
            children: [
              FotoEditavel(
                foto: FotoPerfil(
                    dados: {...p, 'nome': nome},
                    raio: 50,
                    fotoUrl: user.photoURL),
                onEditar: () => trocarFotoPerfil(context),
              ),
              const SizedBox(height: 10),
              CartaoDados(linhas: [
                LinhaDado('Nome', nome),
                LinhaDado('CPF', formatarCpf(p['cpf'] as String?)),
                LinhaDado('Telefone',
                    formatarTelefone(p['telefone'] as String?)),
                LinhaDado('E-mail',
                    (p['email'] as String?) ?? user.email ?? ''),
                LinhaDado('Nascimento', (p['nascimento'] ?? '').toString(),
                    ultima: true),
              ]),
              const SizedBox(height: 18),
              BotoesConta(
                onEditar: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        EditarPerfilPage(perfil: p, nomeAtual: nome),
                  ),
                ),
                onExcluir: () async {
                  await excluirConta(context);
                  if (FirebaseAuth.instance.currentUser == null &&
                      context.mounted) {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
