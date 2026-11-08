/// DOM adapter shared by the platform rasterizers. It works only on trusted,
/// escaped upstream markup and never evaluates form methods or events.
enum CanvasScripts {
    /// Async function body: isolates the selected canvas and returns {width, height}.
    static let prepare = """
    const svg = [...document.querySelectorAll('.form-page > .form-scroll > svg')]
      .find(s => s.closest('.form-appearance').offsetHeight > 0 &&
                 s.closest('.form-page').offsetHeight > 0);
    if (!svg) throw new Error('No selected form canvas in shared renderer output');
    const width = Number(svg.getAttribute('width'));
    const height = Number(svg.getAttribute('height'));
    if (!(width >= 1 && height >= 1 && width <= 8192 && height <= 8192))
      throw new Error('Invalid shared canvas size');
    await document.fonts.ready;
    await Promise.all([...document.querySelectorAll('image')].map(async node => {
      const image = new Image();
      image.src = node.getAttribute('href');
      await image.decode();
    }));
    const preview = document.querySelector('.form-preview');
    const appearance = svg.closest('.form-appearance');
    for (const node of [...document.querySelectorAll('body style')]) document.head.appendChild(node);
    document.body.replaceChildren(preview);
    for (const node of [...preview.children]) {
      if (node !== appearance && node.tagName !== 'STYLE' && node.tagName !== 'svg') node.remove();
    }
    for (const node of [...appearance.children]) {
      if (!node.contains(svg)) node.remove();
    }
    const style = document.createElement('style');
    style.textContent = `html,body{margin:0!important;padding:0!important;overflow:hidden!important}
      body *{animation:none!important;transition:none!important}
      .form-preview,.form-appearance,.form-page,.form-scroll{margin:0!important;
      padding:0!important;border:0!important;max-width:none!important;max-height:none!important;
      overflow:visible!important}
      .form-caption,.form-themes,.form-pages{display:none!important}
      .form-appearance,.form-page{display:block!important}
      .form-scroll>svg{display:block!important}`;
    document.head.appendChild(style);
    return {width,height};
    """

    /// Async function body receiving `width` and `height` output pixels.
    static let resize = """
    const svg = document.querySelector('.form-page > .form-scroll > svg');
    svg.setAttribute('width', width); svg.setAttribute('height', height);
    return {width: svg.getBoundingClientRect().width, height: svg.getBoundingClientRect().height};
    """
}
