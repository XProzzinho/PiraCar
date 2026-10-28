import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat.dart';
import 'foto.dart';
import 'foto_trocar.dart';
import 'menu_visual.dart';
import 'telas_menu.dart';
import 'cores.dart';

const azulNoite = Color(0xFF0B2545);
const amarelo = Color(0xFFFFC24B);
const _azul = Color(0xFF1565C0);

/// Título "Uai Car" com o "Car" em amarelo, usado na barra do topo.
class MarcaPiraCar extends StatelessWidget {
  const MarcaPiraCar({super.key});

  @override
  Widget build(BuildContext context) {
    return const Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Uai ', style: TextStyle(color: Colors.white)),
          TextSpan(text: 'Car', style: TextStyle(color: amarelo)),
        ],
      ),
      style: TextStyle(
          fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5),
    );
  }
}

/// Só os números do texto.
String soDigitos(String s) => s.replaceAll(RegExp(r'\D'), '');

/// Valor em reais: 16.4 -> "R\$ 16,40".
String formatarReal(num v) =>
    'R\$ ${v.toDouble().toStringAsFixed(2).replaceAll('.', ',')}';

String formatarCpf(String? cpf) {
  final d = soDigitos(cpf ?? '');
  if (d.length != 11) return cpf ?? '';
  return '${d.substring(0, 3)}.${d.substring(3, 6)}.${d.substring(6, 9)}-${d.substring(9)}';
}

String formatarTelefone(String? tel) {
  final d = soDigitos(tel ?? '');
  if (d.length == 11) {
    return '(${d.substring(0, 2)}) ${d.substring(2, 7)}-${d.substring(7)}';
  }
  if (d.length == 10) {
    return '(${d.substring(0, 2)}) ${d.substring(2, 6)}-${d.substring(6)}';
  }
  return tel ?? '';
}

bool cpfValido(String cpf) {
  final d = soDigitos(cpf).split('').map(int.parse).toList();
  if (d.length != 11 || d.toSet().length == 1) return false;
  int digito(int n) {
    var soma = 0;
    for (var i = 0; i < n; i++) {
      soma += d[i] * (n + 1 - i);
    }
    final r = (soma * 10) % 11;
    return r == 10 ? 0 : r;
  }

  return digito(9) == d[9] && digito(10) == d[10];
}


/// Menu lateral do passageiro (três tracinhos), no estilo gaveta.
class MenuLateral extends StatelessWidget {
  const MenuLateral({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (context, snapPerfil) {
        final perfil = snapPerfil.data?.data() ?? const <String, dynamic>{};
        final nome = (perfil['nome'] as String?)?.trim().isNotEmpty == true
            ? perfil['nome'] as String
            : (user.displayName ?? 'Passageiro');

        void chat(BuildContext c) => abrirDoMenu(
              c,
              ChatPage(
                uid: user.uid,
                souAdmin: false,
                titulo: 'Fale conosco',
                nomeUsuario: nome,
              ),
            );

        return GavetaPiraCar(
          cabecalho: CabecalhoMenu(
            nome: nome,
            subtitulo: formatarTelefone(perfil['telefone'] as String?),
            foto: FotoPerfil(
                dados: {...perfil, 'nome': nome},
                raio: 38,
                fotoUrl: user.photoURL),
            onFoto: () => trocarFotoPerfil(context),
          ),
          itens: [
            ItemMenu(Icons.explore_outlined, 'Minhas viagens',
                () => abrirDoMenu(context, const MinhasViagensPage()),
                destaque: true),
            ItemMenu(Icons.confirmation_number_outlined, 'Adicionar cupom',
                () => abrirDoMenu(context, const CupomPage())),
            ItemMenu(Icons.campaign_outlined, 'Divulgação',
                () => abrirDoMenu(context, const DivulgacaoPage())),
            ItemMenu(Icons.help_outline, 'Ajuda', () {
              abrirDoMenu(
                context,
                Builder(
                  builder: (c) => AjudaPage(
                    abrirChat: () => Navigator.push(
                      c,
                      MaterialPageRoute(
                        builder: (_) => ChatPage(
                          uid: user.uid,
                          souAdmin: false,
                          titulo: 'Fale conosco',
                          nomeUsuario: nome,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
            StreamBuilder<int>(
              stream: naoLidas(user.uid, souAdmin: false),
              builder: (context, snap) => ItemMenu(
                Icons.support_agent_outlined,
                'Fale conosco',
                () => chat(context),
                contador: snap.data ?? 0,
              ),
            ),
            ItemMenu(Icons.settings_outlined, 'Configurações',
                () => abrirDoMenu(context, const ConfiguracoesPage())),
            ItemMenu(Icons.logout, 'Sair', () {
              Navigator.pop(context);
              FirebaseAuth.instance.signOut();
            }),
          ],
        );
      },
    );
  }
}

/// Tela para o passageiro completar ou corrigir os próprios dados.
class EditarPerfilPage extends StatefulWidget {
  const EditarPerfilPage(
      {super.key, required this.perfil, required this.nomeAtual});

  final Map<String, dynamic> perfil;
  final String nomeAtual;

  @override
  State<EditarPerfilPage> createState() => _EditarPerfilPageState();
}

class _EditarPerfilPageState extends State<EditarPerfilPage> {
  final _form = GlobalKey<FormState>();
  late final _nome = TextEditingController(text: widget.nomeAtual);
  late final _cpf = TextEditingController(
      text: soDigitos(widget.perfil['cpf'] as String? ?? ''));
  late final _telefone = TextEditingController(
      text: soDigitos(widget.perfil['telefone'] as String? ?? ''));
  late final _nascimento = TextEditingController(
      text: soDigitos(widget.perfil['nascimento'] as String? ?? ''));
  bool _salvando = false;

  @override
  void dispose() {
    _nome.dispose();
    _cpf.dispose();
    _telefone.dispose();
    _nascimento.dispose();
    super.dispose();
  }

  Future<void> _salvar() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _salvando = true);
    final nasc = soDigitos(_nascimento.text);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(FirebaseAuth.instance.currentUser!.uid)
          .update({
        'nome': _nome.text.trim(),
        'cpf': soDigitos(_cpf.text),
        'telefone': soDigitos(_telefone.text),
        'nascimento': nasc.length == 8
            ? '${nasc.substring(0, 2)}/${nasc.substring(2, 4)}/${nasc.substring(4)}'
            : '',
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não foi possível salvar: $e')));
    } finally {
      if (mounted) setState(() => _salvando = false);
    }
  }

  InputDecoration _decoracao(String rotulo, IconData icone, {String? dica}) {
    final borda = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: ln(Color(0xFFE2E8F0)), width: 1.5),
    );
    return InputDecoration(
      labelText: rotulo,
      hintText: dica,
      prefixIcon: Icon(icone, size: 20),
      filled: true,
      fillColor: fu(Color(0xFFF4F6FA)),
      enabledBorder: borda,
      border: borda,
      focusedBorder: borda.copyWith(
          borderSide: const BorderSide(color: _azul, width: 1.5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final digitos = [FilteringTextInputFormatter.digitsOnly];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meus dados'),
        centerTitle: true,
        backgroundColor: azulNoite,
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _nome,
              textCapitalization: TextCapitalization.words,
              decoration: _decoracao('Nome completo', Icons.person_outline),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Informe seu nome' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _cpf,
              keyboardType: TextInputType.number,
              inputFormatters: [
                ...digitos,
                LengthLimitingTextInputFormatter(11)
              ],
              decoration: _decoracao('CPF', Icons.badge_outlined,
                  dica: 'Só números'),
              validator: (v) => (v ?? '').isEmpty || cpfValido(v!)
                  ? null
                  : 'CPF inválido',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _telefone,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                ...digitos,
                LengthLimitingTextInputFormatter(11)
              ],
              decoration: _decoracao('Telefone com DDD', Icons.phone_outlined,
                  dica: '38999999999'),
              validator: (v) => (v ?? '').isEmpty || v!.length >= 10
                  ? null
                  : 'Telefone incompleto',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nascimento,
              keyboardType: TextInputType.number,
              inputFormatters: [
                ...digitos,
                LengthLimitingTextInputFormatter(8)
              ],
              decoration: _decoracao(
                  'Data de nascimento', Icons.cake_outlined,
                  dica: 'DDMMAAAA'),
              validator: (v) => (v ?? '').isEmpty || v!.length == 8
                  ? null
                  : 'Use dia, mês e ano: DDMMAAAA',
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 54,
              child: FilledButton(
                onPressed: _salvando ? null : _salvar,
                style: FilledButton.styleFrom(
                  backgroundColor: _azul,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(_salvando ? 'Salvando...' : 'Salvar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
