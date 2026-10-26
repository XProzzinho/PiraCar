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
