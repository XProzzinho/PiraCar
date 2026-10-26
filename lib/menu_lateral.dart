import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const azulNoite = Color(0xFF0B2545);
const amarelo = Color(0xFFFFC24B);
const _azul = Color(0xFF1565C0);
const _textoSuave = Color(0xFF5B6577);

/// Título "PiraCar" com o "Car" em amarelo, usado na barra do topo.
class MarcaPiraCar extends StatelessWidget {
  const MarcaPiraCar({super.key});

  @override
  Widget build(BuildContext context) {
    return const Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Pira', style: TextStyle(color: Colors.white)),
          TextSpan(text: 'Car', style: TextStyle(color: amarelo)),
        ],
      ),
      style: TextStyle(
          fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5),
    );
  }
}

String _soDigitos(String s) => s.replaceAll(RegExp(r'\D'), '');

String formatarCpf(String? cpf) {
  final d = _soDigitos(cpf ?? '');
  if (d.length != 11) return cpf ?? '';
  return '${d.substring(0, 3)}.${d.substring(3, 6)}.${d.substring(6, 9)}-${d.substring(9)}';
}

String formatarTelefone(String? tel) {
  final d = _soDigitos(tel ?? '');
  if (d.length == 11) {
    return '(${d.substring(0, 2)}) ${d.substring(2, 7)}-${d.substring(7)}';
  }
  if (d.length == 10) {
    return '(${d.substring(0, 2)}) ${d.substring(2, 6)}-${d.substring(6)}';
  }
  return tel ?? '';
}

bool cpfValido(String cpf) {
  final d = _soDigitos(cpf).split('').map(int.parse).toList();
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

const _meses = [
  'jan', 'fev', 'mar', 'abr', 'mai', 'jun',
  'jul', 'ago', 'set', 'out', 'nov', 'dez',
];

String _iniciais(String nome) {
  final partes = nome.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  if (partes.isEmpty) return '?';
  final primeira = partes.first[0];
  final ultima = partes.length > 1 ? partes.last[0] : '';
  return (primeira + ultima).toUpperCase();
}

/// Menu lateral do passageiro: foto, nome, avaliação dada pelos motoristas
/// e os dados da conta.
class MenuLateral extends StatelessWidget {
  const MenuLateral({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    final db = FirebaseFirestore.instance;

    return Drawer(
      backgroundColor: Colors.white,
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: db.collection('users').doc(user.uid).snapshots(),
        builder: (context, snapPerfil) {
          final perfil = snapPerfil.data?.data() ?? const {};
          final nome = (perfil['nome'] as String?)?.trim().isNotEmpty == true
              ? perfil['nome'] as String
              : (user.displayName ?? 'Passageiro');
          final criadoEm = perfil['criadoEm'];

          return Column(
            children: [
              _Cabecalho(
                nome: nome,
                fotoUrl: user.photoURL,
                desde: criadoEm is Timestamp ? criadoEm.toDate() : null,
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    const _Secao('Meus dados'),
                    _Dado(Icons.person_outline, 'Nome', nome),
                    _Dado(Icons.badge_outlined, 'CPF',
                        formatarCpf(perfil['cpf'] as String?)),
                    _Dado(Icons.phone_outlined, 'Telefone',
                        formatarTelefone(perfil['telefone'] as String?)),
                    _Dado(Icons.mail_outline, 'E-mail',
                        (perfil['email'] as String?) ?? user.email ?? ''),
                    _Dado(Icons.cake_outlined, 'Data de nascimento',
                        (perfil['nascimento'] as String?) ?? ''),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => EditarPerfilPage(
                                  perfil: perfil, nomeAtual: nome),
                            ),
                          );
                        },
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Editar dados'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _azul,
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout, color: Color(0xFFC62828)),
                title: const Text('Sair',
                    style: TextStyle(
                        color: Color(0xFFC62828),
                        fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(context);
                  FirebaseAuth.instance.signOut();
                },
              ),
              SizedBox(height: MediaQuery.paddingOf(context).bottom),
            ],
          );
        },
      ),
    );
  }
}

class _Cabecalho extends StatelessWidget {
  const _Cabecalho({required this.nome, this.fotoUrl, this.desde});

  final String nome;
  final String? fotoUrl;
  final DateTime? desde;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final topo = MediaQuery.paddingOf(context).top;

    return Container(
      width: double.infinity,
      color: azulNoite,
      padding: EdgeInsets.fromLTRB(20, topo + 20, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration:
                const BoxDecoration(color: amarelo, shape: BoxShape.circle),
            child: CircleAvatar(
              radius: 32,
              backgroundColor: const Color(0xFF1B3A63),
              foregroundImage: fotoUrl != null ? NetworkImage(fotoUrl!) : null,
              child: Text(_iniciais(nome),
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          ),
          const SizedBox(height: 14),
          Text(nome,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.white)),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('corridas')
                .where('passageiroId', isEqualTo: uid)
                .snapshots(),
            builder: (context, snap) {
              final corridas = snap.data?.docs ?? const [];
              final notas = corridas
                  .map((d) => d.data()['avaliacaoPassageiro'])
                  .whereType<num>()
                  .toList();
              final feitas = corridas
                  .where((d) => d.data()['status'] == 'finalizada')
                  .length;
              final media = notas.isEmpty
                  ? null
                  : notas.reduce((a, b) => a + b) / notas.length;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Pilula(
                    icone: Icons.star_rounded,
                    corIcone: amarelo,
                    texto: media == null
                        ? 'Sem avaliações'
                        : '${media.toStringAsFixed(1).replaceAll('.', ',')}'
                            ' · ${notas.length} '
                            '${notas.length == 1 ? 'avaliação' : 'avaliações'}',
                  ),
                  _Pilula(
                    icone: Icons.local_taxi_outlined,
                    corIcone: Colors.white,
                    texto: '$feitas ${feitas == 1 ? 'corrida' : 'corridas'}',
                  ),
                ],
              );
            },
          ),
          if (desde != null) ...[
            const SizedBox(height: 10),
            Text('Passageiro desde ${_meses[desde!.month - 1]}/${desde!.year}',
                style: const TextStyle(fontSize: 13, color: Color(0xFFC9D6EA))),
          ],
        ],
      ),
    );
  }
}

class _Pilula extends StatelessWidget {
  const _Pilula(
      {required this.icone, required this.corIcone, required this.texto});

  final IconData icone;
  final Color corIcone;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x26FFFFFF),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icone, size: 16, color: corIcone),
          const SizedBox(width: 4),
          Text(texto,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ],
      ),
    );
  }
}

class _Secao extends StatelessWidget {
  const _Secao(this.titulo);

  final String titulo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(titulo.toUpperCase(),
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: _textoSuave)),
    );
  }
}

class _Dado extends StatelessWidget {
  const _Dado(this.icone, this.rotulo, this.valor);

  final IconData icone;
  final String rotulo;
  final String valor;

  @override
  Widget build(BuildContext context) {
    final vazio = valor.trim().isEmpty;
    return ListTile(
      dense: true,
      leading: Icon(icone, color: const Color(0xFF64748B)),
      title: Text(rotulo,
          style: const TextStyle(fontSize: 12, color: _textoSuave)),
      subtitle: Text(vazio ? 'Não informado' : valor,
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: vazio ? const Color(0xFF94A3B8) : const Color(0xFF0F172A))),
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
      text: _soDigitos(widget.perfil['cpf'] as String? ?? ''));
  late final _telefone = TextEditingController(
      text: _soDigitos(widget.perfil['telefone'] as String? ?? ''));
  late final _nascimento = TextEditingController(
      text: _soDigitos(widget.perfil['nascimento'] as String? ?? ''));
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
    final nasc = _soDigitos(_nascimento.text);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(FirebaseAuth.instance.currentUser!.uid)
          .update({
        'nome': _nome.text.trim(),
        'cpf': _soDigitos(_cpf.text),
        'telefone': _soDigitos(_telefone.text),
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
      borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
    );
    return InputDecoration(
      labelText: rotulo,
      hintText: dica,
      prefixIcon: Icon(icone, size: 20),
      filled: true,
      fillColor: const Color(0xFFF4F6FA),
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
