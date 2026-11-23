// ===========================================================================
// PANTALLA "TIENDA Y COLECCIÓN" (dentro de Ajustes)
// ===========================================================================
import 'package:flutter/material.dart';

import 'cosmetics_catalog.dart';
import 'effects.dart';
import 'main.dart';
import 'progress.dart';

class RewardsPage extends StatefulWidget {
  const RewardsPage({super.key});
  @override
  State<RewardsPage> createState() => _RewardsPageState();
}

class _RewardsPageState extends State<RewardsPage> {
  CosCat? _filter;

  @override
  void initState() {
    super.initState();
    progress.watchers++;
  }

  @override
  void dispose() {
    progress.watchers--;
    progress.markSeen();
    super.dispose();
  }

  Widget _header(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = kCosmetics.length;
    final got = progress.unlocked.length;
    final next = progress.next;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.emoji_events_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    progress.title != null
                        ? progress.name(progress.title!)
                        : tr('Tu colección', 'Your collection'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text('$got / $total',
                    style: TextStyle(
                        color: cs.primary, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: got / total, minHeight: 8),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _stat(Icons.phone_android, tr('En la app', 'In the app'),
                      fmtTime(progress.appSec)),
                ),
                Expanded(
                  child: _stat(Icons.headphones, tr('Escuchando', 'Listening'),
                      fmtTime(progress.listenSec)),
                ),
              ],
            ),
            const Divider(height: 24),
            if (next == null)
              Text(tr('¡Completaste toda la colección!',
                  'You completed the whole collection!'))
            else ...[
              Text(tr('Próximo desbloqueo', 'Next unlock'),
                  style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(
                '${progress.name(next)} · ${catName(next.cat, ctrl.lang == 'es')}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                '${tr('Faltan', 'Left')} ${fmtTime(progress.remaining(next))} '
                '${next.listen ? tr('de escucha', 'of listening') : tr('en la app', 'in the app')}',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stat(IconData i, String label, String value) {
    return Row(
      children: [
        Icon(i, size: 20),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }

  Widget _filters() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(tr('Todo', 'All')),
              selected: _filter == null,
              onSelected: (_) => setState(() => _filter = null),
            ),
          ),
          for (final c in CosCat.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: Icon(catIcon(c), size: 16),
                label: Text(catName(c, ctrl.lang == 'es')),
                selected: _filter == c,
                onSelected: (_) => setState(() => _filter = c),
              ),
            ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, Cosmetic c) {
    final cs = Theme.of(context).colorScheme;
    final open = progress.isUnlocked(c);
    final equipped = progress.isEquipped(c);
    final isNew = progress.fresh.contains(c.id);
    final nm = progress.name(c);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: equipped
            ? BorderSide(color: cs.primary, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: open ? 1 : 0.35,
                    child: Center(child: cosPreview(c, nm)),
                  ),
                  if (!open) const Icon(Icons.lock_outline, size: 28),
                  if (isNew)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(tr('NUEVO', 'NEW'),
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: cs.onPrimary)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(nm,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            if (open)
              SizedBox(
                width: double.infinity,
                child: equipped
                    ? OutlinedButton(
                        onPressed: () => progress.unequip(c.cat),
                        child: Text(tr('Quitar', 'Unequip')),
                      )
                    : FilledButton(
                        onPressed: () => progress.equip(c),
                        child: Text(tr('Equipar', 'Equip')),
                      ),
              )
            else ...[
              LinearProgressIndicator(value: progress.fraction(c)),
              const SizedBox(height: 4),
              Text(
                '${tr('Faltan', 'Left')} ${fmtTime(progress.remaining(c))}\n'
                '${c.listen ? tr('de escucha', 'of listening') : tr('en la app', 'in the app')}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: progress,
      builder: (context, _) {
        final items = kCosmetics
            .where((c) => _filter == null || c.cat == _filter)
            .toList();
        return Scaffold(
          appBar: AppBar(title: Text(tr('Tienda y colección', 'Store and collection'))),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _header(context)),
              SliverToBoxAdapter(child: _filters()),
              SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.72,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _card(context, items[i]),
                    childCount: items.length,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  child: TextButton.icon(
                    icon: const Icon(Icons.restart_alt),
                    label: Text(tr('Reiniciar progreso', 'Reset progress')),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(tr('¿Reiniciar progreso?', 'Reset progress?')),
                          content: Text(tr(
                              'Se borrará el tiempo acumulado y todo volverá a estar bloqueado.',
                              'Accumulated time will be erased and everything will be locked again.')),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(tr('Cancelar', 'Cancel')),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(tr('Reiniciar', 'Reset')),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) await progress.reset();
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
