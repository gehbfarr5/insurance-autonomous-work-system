/* Component-level provides traversal candidate, offline / read-only by design.
   This file does NOT connect, navigate, dispatch, or call any set function.
   It is a candidate for a future read-only probe; it is not deployed here.
   Coverage correction vs app-only code:
   - Old code only read app._context.provides (string keys via Object.keys).
   - This candidate, for every component instance found by BFS over
     subTree/children/dynamicChildren, enumerates that instance's own provides
     AND its prototype chain: provides, Object.getPrototypeOf(provides), ...
     until null, with a per-level list. A Symbol found only on a prototype
     is reported as level>=1, inherited, not own.
   - Cycles: WeakSet for instances, vnodes, and provides objects, per run.
   - Bounds: 5000 objects, 250 depth, 12000 queue, 160 metadata keys.
   - Ref rule: a ref object (__v_isRef true) is unwrapped to its _value ONLY
     when the field key is in the whitelist AND _value is boolean; otherwise
     only type is reported, never the value. Non-ref fields: whitelist boolean
     direct values only when the value is boolean; otherwise type/length/keys
     only. Accessor descriptors are reported as type "accessor" and never invoked.
   - No string values, no ID values, no text, no function bodies, no set calls.
   - Per-run state: all traversal state is created inside run(), so a second
     run({}) correctly returns ROOT_NOT_EXPOSED (fix for the first offline
     test failure, where module-level state leaked across runs).
*/
(() => {
  const ALLOW = new Set(['isAnswering','contentLoading','isShowStopButton','isStopAnswer',
    'endAnswerFlag','endThinkContentFlag','error','isAnswerDone','isAnswerLoading',
    'isThinkLoading','isAnswerPaused','isThinkPaused','isShowConversationHistory']);
  return function run(rootContainer) {
    const errors = [], nodes = [], entries = [];
    const seenInstances = new WeakSet(), seenVnodes = new WeakSet();
    const queue = [], queuedInstances = new WeakSet(), queuedVnodes = new WeakSet();
    const truncationReasons = new Set();
    let visited = 0, truncated = false;
    function read(o, k, path) { if (!o) return undefined; try { return o[k]; } catch (e) { errors.push({path, errorType: e.name}); return undefined; } }
    function budget(depth) {
      if (depth > 250) { truncated = true; truncationReasons.add('DEPTH'); return false; }
      if (visited++ >= 5000) { truncated = true; truncationReasons.add('OBJECT_COUNT'); return false; }
      return true;
    }
    function enqueue(kind, obj, path, depth) {
      if (!obj || typeof obj !== 'object') return;
      const q = kind === 'component' ? queuedInstances : queuedVnodes;
      if (q.has(obj)) return;
      if (queue.length >= 12000) { truncated = true; truncationReasons.add('QUEUE_COUNT'); return; }
      q.add(obj); queue.push({kind, object: obj, path, depth});
    }
    function ownData(obj, key) {
      const descriptor = Object.getOwnPropertyDescriptor(obj, key);
      return descriptor && 'value' in descriptor ? descriptor.value : undefined;
    }
    function fieldMeta(obj, path) {
      if (!obj || typeof obj !== 'object') return [];
      let descs; try { descs = Object.getOwnPropertyDescriptors(obj); } catch (e) { errors.push({path, errorType: e.name}); return []; }
      const keys = Object.keys(descs);
      if (keys.length > 160) { truncated = true; truncationReasons.add('METADATA_KEYS'); }
      return keys.slice(0, 160).map(key => {
        const d = descs[key];
        if (!('value' in d)) return {key, type: 'accessor'};
        const v = d.value;
        if (v !== null && typeof v === 'object' && ownData(v, '__v_isRef') === true) {
          if (ALLOW.has(key) && typeof ownData(v, '_value') === 'boolean') return {key, type: 'ref-boolean', boolean: ownData(v, '_value')};
          return {key, type: 'ref'};
        }
        if (ALLOW.has(key) && typeof v === 'boolean') return {key, type: 'boolean', boolean: v};
        if (Array.isArray(v)) return {key, type: 'array', length: v.length};
        if (v !== null && typeof v === 'object') return {key, type: 'object', keys: Object.keys(v).slice(0, 50)};
        return {key, type: typeof v};
      });
    }
    function providesChain(instance, path) {
      const prov = read(instance, 'provides', path + '.provides');
      if (!prov || typeof prov !== 'object') return [];
      const levels = []; const seenProvides = new WeakSet(); let cur = prov, level = 0;
      while (cur !== null && typeof cur === 'object' && level < 20) {
        if (seenProvides.has(cur)) { levels.push({level, cycle: true, stringKeys: [], symbols: []}); break; }
        if (!budget(level)) break;
        seenProvides.add(cur);
        const allStringKeys = Object.keys(cur);
        if (allStringKeys.length > 160) { truncated = true; truncationReasons.add('PROVIDES_KEYS'); }
        const stringKeys = allStringKeys.slice(0,160);
        const symbols = [];
        try {
          const symbolKeys = Object.getOwnPropertySymbols(cur);
          if (symbolKeys.length > 160) { truncated = true; truncationReasons.add('PROVIDES_SYMBOLS'); }
          for (const s of symbolKeys.slice(0,160)) {
            const descriptor = Object.getOwnPropertyDescriptor(cur, s);
            if (!descriptor || !('value' in descriptor)) { symbols.push({description: s.description || null, type:'accessor', fields:[]}); continue; }
            const val = descriptor.value;
            symbols.push({description: s.description || null, type: typeof val, fields: (val !== null && typeof val === 'object') ? fieldMeta(val, path + '.provides-symbol') : []});
          }
        } catch (e) { errors.push({path: path + '.provides-symbols', errorType: e.name}); }
        levels.push({level, own: level === 0, stringKeys, symbols});
        cur = Object.getPrototypeOf(cur); level++;
      }
      if (level >= 20) { truncated = true; truncationReasons.add('PROVIDES_CHAIN_DEPTH'); }
      return levels;
    }
    function inspectComponent(inst, path, depth) {
      if (!inst || typeof inst !== 'object' || seenInstances.has(inst)) return;
      if (!budget(depth)) return;
      seenInstances.add(inst);
      const type = read(inst, 'type', path + '.type');
      const name = read(type, 'name', path + '.type.name') || read(type, '__name', path + '.type.__name');
      nodes.push({path, name: typeof name === 'string' && /^[A-Za-z_$][\w$-]{0,79}$/.test(name) ? name : null,
        setupState: fieldMeta(read(inst, 'setupState', path + '.setupState'), path + '.setupState'),
        props: fieldMeta(read(inst, 'props', path + '.props'), path + '.props'),
        exposed: fieldMeta(read(inst, 'exposed', path + '.exposed'), path + '.exposed'),
        providesChain: providesChain(inst, path)});
      const sub = read(inst, 'subTree', path + '.subTree');
      if (sub) enqueue('vnode', sub, path + '.subTree', depth + 1);
    }
    function inspectVnode(v, path, depth) {
      if (!v || typeof v !== 'object' || seenVnodes.has(v)) return;
      if (!budget(depth)) return;
      seenVnodes.add(v);
      const comp = read(v, 'component', path + '.component');
      if (comp) enqueue('component', comp, path + '.component', depth + 1);
      for (const key of ['children', 'dynamicChildren']) {
        const children = read(v, key, path + '.' + key);
        if (Array.isArray(children)) {
          if (children.length > 300) { truncated = true; truncationReasons.add('VNODE_CHILDREN'); }
          children.slice(0, 300).forEach((child, i) => enqueue('vnode', child, path + '.' + key + '[' + i + ']', depth + 1));
        }
      }
      const susp = read(v, 'suspense', path + '.suspense');
      if (susp) { const branch = read(susp, 'activeBranch', path + '.suspense.activeBranch'); if (branch) enqueue('vnode', branch, path + '.suspense.activeBranch', depth + 1); }
    }
    const container = rootContainer;
    const app = read(container, '__vue_app__', '#app.__vue_app__');
    const roots = [
      ['#app.__vue_app__._instance', read(app, '_instance', 'app._instance'), 'component'],
      ['#app._vnode', read(container, '_vnode', '#app._vnode'), 'vnode'],
      ['#app.__vue_app__._container._vnode', read(read(app, '_container', 'app._container'), '_vnode', 'app._container._vnode'), 'vnode'],
      ['#app.__vueParentComponent', read(container, '__vueParentComponent', '#app.__vueParentComponent'), 'component'],
      ['#app.__vnode', read(container, '__vnode', '#app.__vnode'), 'vnode'],
    ];
    for (const [p, o, kind] of roots) { entries.push({path: p, present: !!o}); if (kind === 'component') enqueue('component', o, p, 0); else enqueue('vnode', o, p, 0); }
    for (let c = 0; c < queue.length; c++) {
      const item = queue[c];
      if (item.kind === 'component') inspectComponent(item.object, item.path, item.depth); else inspectVnode(item.object, item.path, item.depth);
      if (visited >= 5000) { truncated = true; truncationReasons.add('OBJECT_COUNT'); break; }
    }
    return {status: errors.length ? 'READ_ERROR' : truncated ? 'TRUNCATED' : nodes.length ? 'ROOTS_FOUND' : 'ROOT_NOT_EXPOSED',
      entries, nodes, errors, truncated, truncationReasons: [...truncationReasons], nodeCount: nodes.length,
      visitedObjects: visited, queuedObjects: queue.length,
      limits: {visitedObjects: 5000, depth: 250, queueObjects: 12000, metadataKeysPerObject: 160, providesChainDepth: 20}};
  };
})();
