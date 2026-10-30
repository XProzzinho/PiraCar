import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Um passo do "Como funciona" mostrado depois do cadastro.
class PassoTutorial {
  const PassoTutorial(this.icone, this.titulo, this.texto);

  final IconData icone;
  final String titulo;
  final String texto;
}

const passosTutorial = [
  PassoTutorial(Icons.place_outlined, 'Para onde vamos?',
      'Toque em "Para onde vamos?" e digite o endereço ou o nome do lugar. O ponto de partida é onde você está.'),
  PassoTutorial(Icons.receipt_long_outlined, 'Veja o preço antes',
      'O valor aparece antes de pedir. Escolha a categoria e a forma de pagamento: Pix, crédito ou débito.'),
  PassoTutorial(Icons.wifi_tethering, 'O motorista mais perto',
      'Ao pedir, o app chama o motorista mais perto de você. Deixe o app aberto enquanto ele procura o motorista.'),
  PassoTutorial(Icons.directions_car_outlined, 'Acompanhe pelo mapa',
      'Quando o motorista aceitar, você vê o nome, a foto, o carro e a placa, e acompanha ele chegando. Confira a placa antes de entrar. Dá para conversar pelo chat.'),
  PassoTutorial(Icons.star_outline, 'Pague e avalie',
      'Ao chegar, pague direto ao motorista pela forma escolhida e avalie a viagem com estrelas.'),
  PassoTutorial(Icons.menu, 'Tudo no menu',
      'No menu lateral ficam suas viagens, cupons, ajuda, o Fale conosco e os Termos de Uso. Este passo a passo também fica lá, em "Como funciona".'),
];

/// Abre o passo a passo se a conta acabou de ser criada (mostrarTutorial).
Future<void> mostrarTutorialSeNovo(BuildContext context, String uid) async {
  final ref = FirebaseFirestore.instance.collection('users').doc(uid);
  try {
    final doc = await ref.get();
    if (doc.data()?['mostrarTutorial'] != true || !context.mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const ComoFuncionaPage()));
    await ref.update({'mostrarTutorial': false});
  } catch (_) {}
}

/// Passo a passo de como o app funciona, uma tela por passo.
class ComoFuncionaPage extends StatefulWidget {
  const ComoFuncionaPage({super.key, this.onFim});

  /// Sem onFim, ao terminar a tela só fecha.
  final VoidCallback? onFim;

  @override
  State<ComoFuncionaPage> createState() => _ComoFuncionaPageState();
}

class _ComoFuncionaPageState extends State<ComoFuncionaPage> {
  static const _fundo = Color(0xFF0B2545);
  static const _amarelo = Color(0xFFFFC24B);

  final _paginas = PageController();
  int _atual = 0;

  @override
  void dispose() {
    _paginas.dispose();
    super.dispose();
  }

  void _terminar() {
    if (widget.onFim != null) {
      widget.onFim!();
    } else {
      Navigator.maybePop(context);
    }
  }

  void _proximo() {
    if (_atual == passosTutorial.length - 1) {
      _terminar();
    } else {
      _paginas.nextPage(
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ultimo = _atual == passosTutorial.length - 1;
    return Scaffold(
      backgroundColor: _fundo,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _terminar,
                child: const Text('Pular',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _paginas,
                itemCount: passosTutorial.length,
                onPageChanged: (i) => setState(() => _atual = i),
                itemBuilder: (context, i) {
                  final p = passosTutorial[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 150,
                          height: 150,
                          decoration: const BoxDecoration(
                              color: Color(0x1FFFFFFF), shape: BoxShape.circle),
                          child: Center(
                            child: Container(
                              width: 104,
                              height: 104,
                              decoration: const BoxDecoration(
                                  color: _amarelo, shape: BoxShape.circle),
                              child: Icon(p.icone, size: 54, color: _fundo),
                            ),
                          ),
                        ),
                        const SizedBox(height: 36),
                        Text('Passo ${i + 1} de ${passosTutorial.length}',
                            style: const TextStyle(
                                color: _amarelo,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5)),
                        const SizedBox(height: 10),
                        Text(p.titulo,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 14),
                        Text(p.texto,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Color(0xFFC9D6EA),
                                fontSize: 16.5,
                                height: 1.45)),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < passosTutorial.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _atual ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _atual ? _amarelo : Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: _proximo,
                  style: FilledButton.styleFrom(
                    backgroundColor: _amarelo,
                    foregroundColor: _fundo,
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  child: Text(ultimo ? 'Começar' : 'Próximo'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
