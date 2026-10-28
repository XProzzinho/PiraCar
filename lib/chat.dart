import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'cores.dart';

/// Fale conosco: conversa entre o passageiro e a administração.
///
/// Firestore:
///   chats/{uid do passageiro}
///     nome, ultimaMensagem, atualizadoEm, naoLidasAdmin, naoLidasUsuario
///   chats/{uid}/mensagens/{id}
///     texto, deAdmin (bool), em

const _azulNoite = Color(0xFF0B2545);
const _amarelo = Color(0xFFFFC24B);

DocumentReference<Map<String, dynamic>> conversaRef(String uid) =>
    FirebaseFirestore.instance.collection('chats').doc(uid);

/// Quantas mensagens o lado [souAdmin] ainda não leu nessa conversa.
Stream<int> naoLidas(String uid, {required bool souAdmin}) =>
    conversaRef(uid).snapshots().map((s) {
      final v = s.data()?[souAdmin ? 'naoLidasAdmin' : 'naoLidasUsuario'];
      return v is num ? v.toInt() : 0;
    });

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.uid,
    required this.souAdmin,
    required this.titulo,
    this.nomeUsuario,
  });

  /// uid do passageiro dono da conversa.
  final String uid;
  final bool souAdmin;
  final String titulo;

  /// Nome do passageiro (gravado na conversa para a lista do admin).
  final String? nomeUsuario;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _texto = TextEditingController();
  bool _enviando = false;

  String get _meuContador =>
      widget.souAdmin ? 'naoLidasAdmin' : 'naoLidasUsuario';
  String get _outroContador =>
      widget.souAdmin ? 'naoLidasUsuario' : 'naoLidasAdmin';

  @override
  void initState() {
    super.initState();
    _marcarLidas();
  }

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  Future<void> _marcarLidas() async {
    try {
      await conversaRef(widget.uid)
          .set({_meuContador: 0}, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _enviar() async {
    final t = _texto.text.trim();
    if (t.isEmpty || _enviando) return;
    setState(() => _enviando = true);
    try {
      final ref = conversaRef(widget.uid);
      await ref.collection('mensagens').add({
        'texto': t,
        'deAdmin': widget.souAdmin,
        'em': FieldValue.serverTimestamp(),
      });
      await ref.set({
        if (!widget.souAdmin && widget.nomeUsuario != null)
          'nome': widget.nomeUsuario,
        'ultimaMensagem': t,
        'atualizadoEm': FieldValue.serverTimestamp(),
        _outroContador: FieldValue.increment(1),
        _meuContador: 0,
      }, SetOptions(merge: true));
      _texto.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Não foi possível enviar: $e')));
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  String _hora(dynamic ts) {
    if (ts is! Timestamp) return '';
    final d = ts.toDate();
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)} ${dois(d.hour)}:${dois(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fu(Color(0xFFF4F6FA)),
      appBar: AppBar(
        title: Text(widget.titulo),
        backgroundColor: _azulNoite,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: conversaRef(widget.uid)
                  .collection('mensagens')
                  .orderBy('em', descending: true)
                  .limit(200)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Erro ao carregar: ${snap.error}',
                          textAlign: TextAlign.center),
                    ),
                  );
                }
                final docs = snap.data?.docs ?? const [];
                if (snap.hasData) {
                  // chegou mensagem nova com a conversa aberta: já está lida
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => _marcarLidas());
                }
                if (docs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        widget.souAdmin
                            ? 'Nenhuma mensagem ainda.'
                            : 'Mande sua mensagem. A equipe Bora Car responde por aqui.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: fr(Colors.black54)),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final m = docs[i].data();
                    final minha = (m['deAdmin'] == true) == widget.souAdmin;
                    return Align(
                      alignment:
                          minha ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.78),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                        decoration: BoxDecoration(
                          color: minha ? _azulNoite : Colors.white,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(18),
                            topRight: const Radius.circular(18),
                            bottomLeft: Radius.circular(minha ? 18 : 4),
                            bottomRight: Radius.circular(minha ? 4 : 18),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text((m['texto'] ?? '').toString(),
                                style: TextStyle(
                                    fontSize: 15,
                                    color:
                                        minha ? Colors.white : tx(_azulNoite))),
                            const SizedBox(height: 2),
                            Text(_hora(m['em']),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: minha
                                        ? const Color(0xFFC9D6EA)
                                        : fr(Colors.black45))),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _texto,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Escreva sua mensagem',
                        filled: true,
                        fillColor: sup(Colors.white),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(26),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: _amarelo,
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'Enviar',
                      onPressed: _enviando ? null : _enviar,
                      icon: Icon(Icons.send_rounded, color: _azulNoite),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
