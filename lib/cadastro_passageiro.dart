import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'cadastro_etapas.dart';
import 'termos.dart';
import 'menu_lateral.dart' show cpfValido, soDigitos;

/// Cadastro do passageiro em etapas:
/// 1 Dados pessoais, 2 Foto, 3 E-mail e senha.
class CadastroPassageiroPage extends StatefulWidget {
  const CadastroPassageiroPage({super.key, this.email = ''});

  final String email;

  @override
  State<CadastroPassageiroPage> createState() => _CadastroPassageiroPageState();
}

class _CadastroPassageiroPageState extends State<CadastroPassageiroPage> {
  static const _total = 3;
  int _etapa = 1;
  bool _carregando = false;
  bool _verSenha = false;
  bool _aceitouTermos = false;

  final _nome = TextEditingController();
  final _cpf = TextEditingController();
  final _nascimento = TextEditingController();
  final _telefone = TextEditingController();
  late final _email = TextEditingController(text: widget.email);
  final _senha = TextEditingController();
  final _senha2 = TextEditingController();
  Uint8List? _foto;

  @override
  void dispose() {
    for (final c in [
      _nome, _cpf, _nascimento, _telefone, _email, _senha, _senha2,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _aviso(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  String? _erroDaEtapa() {
    switch (_etapa) {
      case 1:
        if (_nome.text.trim().split(RegExp(r'\s+')).length < 2) {
          return 'Digite seu nome completo.';
        }
        if (!cpfValido(_cpf.text)) return 'CPF inválido. Confira os números.';
        if (!dataValida(_nascimento.text)) {
          return 'Data de nascimento inválida. Use DD/MM/AAAA.';
        }
        if (soDigitos(_telefone.text).length < 10) {
          return 'Digite o telefone com DDD.';
        }
        return null;
      case 2:
        return null; // a foto é opcional
      default:
        if (!_email.text.contains('@')) return 'Digite um e-mail válido.';
        if (_senha.text.length < 6) {
          return 'A senha precisa ter pelo menos 6 caracteres.';
        }
        if (_senha.text != _senha2.text) return 'As senhas não são iguais.';
        if (!_aceitouTermos) {
          return 'Para criar a conta, aceite os Termos de Uso e a Política de Privacidade.';
        }
        return null;
    }
  }

  void _avancar() {
    FocusScope.of(context).unfocus();
    final erro = _erroDaEtapa();
    if (erro != null) {
      _aviso(erro);
      return;
    }
    if (_etapa < _total) {
      setState(() => _etapa++);
    } else {
      _criarConta();
    }
  }

  void _voltar() {
    FocusScope.of(context).unfocus();
    if (_etapa > 1) {
      setState(() => _etapa--);
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> _criarConta() async {
    setState(() => _carregando = true);
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _email.text.trim(), password: _senha.text);
      final user = cred.user!;
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'nome': _nome.text.trim(),
        'email': user.email,
        'cpf': soDigitos(_cpf.text),
        'nascimento': _nascimento.text.trim(),
        'telefone': soDigitos(_telefone.text),
        if (_foto != null) 'foto': base64Encode(_foto!),
        'role': 'passageiro',
        'criadoEm': FieldValue.serverTimestamp(),
        'termosAceitosEm': FieldValue.serverTimestamp(),
        'termosVersao': versaoTermos,
        'mostrarTutorial': true,
      });
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      _aviso(switch (e.code) {
        'email-already-in-use' => 'Esse e-mail já tem conta. Volte e entre.',
        'invalid-email' => 'E-mail inválido.',
        'weak-password' => 'Senha fraca. Use pelo menos 6 caracteres.',
        _ => e.message ?? 'Não foi possível criar a conta.',
      });
    } catch (e) {
      _aviso('Não foi possível concluir o cadastro: $e');
    } finally {
      if (mounted) setState(() => _carregando = false);
    }
  }

  EtapaCadastro _base({
    required String nomeEtapa,
    required String titulo,
    required String subtitulo,
    required List<Widget> campos,
    String botao = 'Próxima etapa',
    Widget? rodape,
  }) {
    return EtapaCadastro(
      key: ValueKey(_etapa),
      etapa: _etapa,
      total: _total,
      nomeEtapa: nomeEtapa,
      titulo: titulo,
      subtitulo: subtitulo,
      campos: campos,
      textoBotao: botao,
      onBotao: _avancar,
      onVoltar: _voltar,
      carregando: _carregando,
      rodape: rodape,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _etapa == 1 && !_carregando,
      onPopInvokedWithResult: (saiu, _) {
        if (!saiu && !_carregando) _voltar();
      },
      child: switch (_etapa) {
        1 => _dados(),
        2 => _fotoEtapa(),
        _ => _acesso(),
      },
    );
  }

  Widget _dados() => _base(
        nomeEtapa: 'Dados pessoais',
        titulo: 'Criar conta',
        subtitulo: 'Leva menos de um minuto.',
        campos: [
          CampoCadastro(
            rotulo: 'Nome completo',
            controle: _nome,
            dica: 'Seu nome',
            icone: Icons.person_outline,
            maiusculas: TextCapitalization.words,
          ),
          CampoCadastro(
            rotulo: 'CPF',
            controle: _cpf,
            dica: '000.000.000-00',
            icone: Icons.badge_outlined,
            teclado: TextInputType.number,
            formatos: [FormatoCpf()],
          ),
          CampoCadastro(
            rotulo: 'Data de nascimento',
            controle: _nascimento,
            dica: 'DD/MM/AAAA',
            icone: Icons.calendar_today_outlined,
            teclado: TextInputType.number,
            formatos: [FormatoData()],
          ),
          CampoCadastro(
            rotulo: 'Telefone',
            controle: _telefone,
            dica: '(38) 99999-9999',
            icone: Icons.phone_outlined,
            teclado: TextInputType.phone,
            formatos: [FormatoTelefone()],
          ),
        ],
      );

  Widget _fotoEtapa() => _base(
        nomeEtapa: 'Foto',
        titulo: 'Sua foto',
        subtitulo: 'Ajuda o motorista a reconhecer você.',
        botao: _foto == null ? 'Pular por agora' : 'Próxima etapa',
        campos: [
          const SizedBox(height: 6),
          CirculoFoto(foto: _foto, onTap: _escolher),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _escolher,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    foregroundColor: corTexto,
                    side: const BorderSide(color: corCampoBorda, width: 2),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  child: Text(_foto == null ? 'Escolher foto' : 'Trocar foto'),
                ),
              ),
            ],
          ),
        ],
      );

  Future<void> _escolher() async {
    final f = await escolherFoto(context,
        titulo: 'Sua foto',
        frontal: true,
        largura: 400,
        qualidade: 70,
        limiteKb: 300);
    if (f != null && mounted) setState(() => _foto = f);
  }

  Widget _acesso() => _base(
        nomeEtapa: 'Acesso',
        titulo: 'Crie seu acesso',
        subtitulo: 'É com esse e-mail e senha que você vai entrar.',
        botao: 'Criar minha conta',
        rodape: AceiteTermos(
          aceito: _aceitouTermos,
          onChanged: (v) => setState(() => _aceitouTermos = v),
        ),
        campos: [
          CampoCadastro(
            rotulo: 'E-mail',
            controle: _email,
            dica: 'voce@email.com',
            icone: Icons.mail_outline,
            teclado: TextInputType.emailAddress,
          ),
          CampoCadastro(
            rotulo: 'Senha',
            controle: _senha,
            dica: 'Mínimo de 6 caracteres',
            icone: Icons.lock_outline,
            senha: !_verSenha,
            sufixo: IconButton(
              tooltip: _verSenha ? 'Ocultar senha' : 'Mostrar senha',
              icon: Icon(
                  _verSenha
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: corTextoSuave,
                  size: 20),
              onPressed: () => setState(() => _verSenha = !_verSenha),
            ),
          ),
          CampoCadastro(
            rotulo: 'Confirme a senha',
            controle: _senha2,
            dica: 'Digite de novo',
            icone: Icons.lock_outline,
            senha: !_verSenha,
          ),
        ],
      );
}
