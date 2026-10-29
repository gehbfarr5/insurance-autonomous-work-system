/* Read-only Vue root metadata. No events, requests, text, IDs, or state writes. */
(() => {
  const container = document.querySelector('#app');
  const flags = new Set(['isAnswering', 'contentLoading', 'isShowStopButton',
    'isStopAnswer', 'endAnswerFlag', 'endThinkContentFlag', 'error',
    'isAnswerDone', 'isAnswerLoading', 'isThinkLoading', 'isAnswerPaused',
    'isThinkPaused']);
  const errors = [], nodes = [], entries = [];
  const seenVnodes = new WeakSet(), seenComponents = new WeakSet();
  let visited = 0, truncated = false;
  function read(object, key, path) {
    if (!object) return undefined;
    try { return object[key]; }
    catch (error) { errors.push({path, errorType: error.name}); return undefined; }
  }
  function metadata(object, path) {
    if (!object || typeof object !== 'object') return [];
    let descriptors;
    try { descriptors = Object.getOwnPropertyDescriptors(object); }
    catch (error) { errors.push({path, errorType: error.name}); return []; }
    const keys = Object.keys(descriptors);
    if (keys.length > 160) truncated = true;
    return keys.slice(0, 160).map(key => {
      const descriptor = descriptors[key];
      const result = {key, type: 'value' in descriptor ? typeof descriptor.value : 'accessor'};
      if (Array.isArray(descriptor.value)) result.length = descriptor.value.length;
      if (flags.has(key)) {
        const value = read(object, key, path + '.' + key);
        if (typeof value === 'boolean') result.boolean = value;
      }
      return result;
    });
  }
  function budget(depth) {
    if (depth > 60 || visited++ >= 600) { truncated = true; return false; }
    return true;
  }
  function component(instance, path, depth) {
    if (!instance || typeof instance !== 'object' || seenComponents.has(instance)) return;
    if (!budget(depth)) return;
    seenComponents.add(instance);
    const type = read(instance, 'type', path + '.type');
    const name = read(type, 'name', path + '.type.name') || read(type, '__name', path + '.type.__name');
    nodes.push({path, name: typeof name === 'string' && /^[A-Za-z_$][\w$-]{0,79}$/.test(name) ? name : null,
      setupState: metadata(read(instance, 'setupState', path + '.setupState'), path + '.setupState'),
      props: metadata(read(instance, 'props', path + '.props'), path + '.props'),
      exposed: metadata(read(instance, 'exposed', path + '.exposed'), path + '.exposed')});
    vnode(read(instance, 'subTree', path + '.subTree'), path + '.subTree', depth + 1);
  }
  function vnode(value, path, depth) {
    if (!value || typeof value !== 'object' || seenVnodes.has(value)) return;
    if (!budget(depth)) return;
    seenVnodes.add(value);
    component(read(value, 'component', path + '.component'), path + '.component', depth + 1);
    for (const key of ['children', 'dynamicChildren']) {
      const children = read(value, key, path + '.' + key);
      if (Array.isArray(children)) {
        if (children.length > 300) truncated = true;
        children.slice(0, 300).forEach((child, index) =>
          vnode(child, path + '.' + key + '[' + index + ']', depth + 1));
      }
    }
    const suspense = read(value, 'suspense', path + '.suspense');
    vnode(read(suspense, 'activeBranch', path + '.suspense.activeBranch'), path + '.suspense.activeBranch', depth + 1);
  }
  const app = read(container, '__vue_app__', '#app.__vue_app__');
  for (const [path, object, kind] of [
    ['#app.__vue_app__._instance', read(app, '_instance', 'app._instance'), 'component'],
    ['#app._vnode', read(container, '_vnode', '#app._vnode'), 'vnode'],
    ['#app.__vue_app__._container._vnode', read(read(app, '_container', 'app._container'), '_vnode', 'app._container._vnode'), 'vnode'],
    ['#app.__vueParentComponent', read(container, '__vueParentComponent', '#app.__vueParentComponent'), 'component'],
    ['#app.__vnode', read(container, '__vnode', '#app.__vnode'), 'vnode']
  ]) {
    entries.push({path, present: !!object});
    if (kind === 'component') component(object, path, 0); else vnode(object, path, 0);
  }
  return {status: errors.length ? 'READ_ERROR' : truncated ? 'TRUNCATED' : nodes.length ? 'ROOTS_FOUND' : 'ROOT_NOT_EXPOSED',
    entries, nodes, errors, truncated, nodeCount: nodes.length,
    limits: {visitedObjects: 600, depth: 60, metadataKeysPerObject: 160}};
})()
