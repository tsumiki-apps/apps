/* ============================================================
   墨の流体シミュレーション（GPU / WebGL）
   紙×墨ポートフォリオのヒーロー背景。スクロール量と指/マウスの
   動きで、透明な紙の上に墨が立ち上り、渦を巻いて拡散する。

   物理コアは Pavel Dobryakov の WebGL-Fluid-Simulation（MIT）の
   手法を土台に、単色・墨・透明合成・スクロール入力へ最小化して再構成。
   ============================================================ */
(function () {
  'use strict';
  const canvas = document.getElementById('inkFluid');
  if (!canvas) return;
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  // ---- 調整パラメータ（濃さ・広がり・流れの強さ） ----
  const config = {
    SIM_RESOLUTION: 128,       // 速度場の解像度
    DYE_RESOLUTION: 640,       // 墨（染料）の解像度
    DENSITY_DISSIPATION: 1.0,  // 墨の消え方（小さいほど長く残る）
    VELOCITY_DISSIPATION: 0.4, // 流れの減衰（少し落ち着かせる）
    PRESSURE: 0.8,
    PRESSURE_ITERATIONS: 20,
    CURL: 4,                   // 渦の強さ（低く＝モヤモヤせず滑らかな塊に）
    SPLAT_RADIUS: 0.30,        // 一滴の広がり（大きめ＝丸い塊）
    SPLAT_FORCE: 5200,         // 指の押し出す力
    INK_STRENGTH: 0.34,        // 一滴で足す墨の濃さ
  };
  const INK = [0.02, 0.02, 0.02];    // 墨色（より黒く・ほぼ漆黒）

  const { gl, ext } = getWebGLContext(canvas);
  if (!gl) return;
  if (!ext.supportLinearFiltering) {
    config.DYE_RESOLUTION = 512;
  }

  // -------------------- WebGL コンテキスト --------------------
  function getWebGLContext(canvas) {
    const params = { alpha: true, depth: false, stencil: false, antialias: false, preserveDrawingBuffer: false, premultipliedAlpha: false };
    let gl = canvas.getContext('webgl2', params);
    const isWebGL2 = !!gl;
    if (!isWebGL2) gl = canvas.getContext('webgl', params) || canvas.getContext('experimental-webgl', params);
    if (!gl) return { gl: null, ext: null };

    let halfFloat, supportLinearFiltering;
    if (isWebGL2) {
      gl.getExtension('EXT_color_buffer_float');
      supportLinearFiltering = gl.getExtension('OES_texture_float_linear');
    } else {
      halfFloat = gl.getExtension('OES_texture_half_float');
      supportLinearFiltering = gl.getExtension('OES_texture_half_float_linear');
    }
    gl.clearColor(0.0, 0.0, 0.0, 0.0);
    const halfFloatTexType = isWebGL2 ? gl.HALF_FLOAT : (halfFloat && halfFloat.HALF_FLOAT_OES);
    let formatRGBA, formatRG, formatR;
    if (isWebGL2) {
      formatRGBA = getSupportedFormat(gl, gl.RGBA16F, gl.RGBA, halfFloatTexType);
      formatRG = getSupportedFormat(gl, gl.RG16F, gl.RG, halfFloatTexType);
      formatR = getSupportedFormat(gl, gl.R16F, gl.RED, halfFloatTexType);
    } else {
      formatRGBA = getSupportedFormat(gl, gl.RGBA, gl.RGBA, halfFloatTexType);
      formatRG = getSupportedFormat(gl, gl.RGBA, gl.RGBA, halfFloatTexType);
      formatR = getSupportedFormat(gl, gl.RGBA, gl.RGBA, halfFloatTexType);
    }
    return { gl, ext: { formatRGBA, formatRG, formatR, halfFloatTexType, supportLinearFiltering: !!supportLinearFiltering } };
  }
  function getSupportedFormat(gl, internalFormat, format, type) {
    if (!supportRenderTextureFormat(gl, internalFormat, format, type)) {
      switch (internalFormat) {
        case gl.R16F: return getSupportedFormat(gl, gl.RG16F, gl.RG, type);
        case gl.RG16F: return getSupportedFormat(gl, gl.RGBA16F, gl.RGBA, type);
        default: return null;
      }
    }
    return { internalFormat, format };
  }
  function supportRenderTextureFormat(gl, internalFormat, format, type) {
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, internalFormat, 4, 4, 0, format, type, null);
    const fbo = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
    const status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
    gl.deleteFramebuffer(fbo); gl.deleteTexture(texture);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    return status === gl.FRAMEBUFFER_COMPLETE;
  }

  // -------------------- シェーダ --------------------
  function compileShader(type, source, keywords) {
    source = addKeywords(source, keywords);
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) console.warn(gl.getShaderInfoLog(shader));
    return shader;
  }
  function addKeywords(source, keywords) {
    if (!keywords) return source;
    let prefix = '';
    keywords.forEach(k => { prefix += '#define ' + k + '\n'; });
    return prefix + source;
  }
  function createProgram(vs, fs) {
    const program = gl.createProgram();
    gl.attachShader(program, vs); gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) console.warn(gl.getProgramInfoLog(program));
    const uniforms = {};
    const count = gl.getProgramParameter(program, gl.ACTIVE_UNIFORMS);
    for (let i = 0; i < count; i++) {
      const name = gl.getActiveUniform(program, i).name;
      uniforms[name] = gl.getUniformLocation(program, name);
    }
    return { program, uniforms };
  }

  const baseVertex = `
    precision highp float;
    attribute vec2 aPosition;
    varying vec2 vUv; varying vec2 vL; varying vec2 vR; varying vec2 vT; varying vec2 vB;
    uniform vec2 texelSize;
    void main () {
      vUv = aPosition * 0.5 + 0.5;
      vL = vUv - vec2(texelSize.x, 0.0);
      vR = vUv + vec2(texelSize.x, 0.0);
      vT = vUv + vec2(0.0, texelSize.y);
      vB = vUv - vec2(0.0, texelSize.y);
      gl_Position = vec4(aPosition, 0.0, 1.0);
    }`;

  const copyFrag = `
    precision mediump float; precision mediump sampler2D;
    varying highp vec2 vUv; uniform sampler2D uTexture;
    void main () { gl_FragColor = texture2D(uTexture, vUv); }`;

  const clearFrag = `
    precision mediump float; precision mediump sampler2D;
    varying highp vec2 vUv; uniform sampler2D uTexture; uniform float value;
    void main () { gl_FragColor = value * texture2D(uTexture, vUv); }`;

  const splatFrag = `
    precision highp float; precision highp sampler2D;
    varying vec2 vUv; uniform sampler2D uTarget; uniform float aspectRatio;
    uniform vec3 color; uniform vec2 point; uniform float radius;
    void main () {
      vec2 p = vUv - point.xy; p.x *= aspectRatio;
      vec3 splat = exp(-dot(p, p) / radius) * color;
      vec3 base = texture2D(uTarget, vUv).xyz;
      gl_FragColor = vec4(base + splat, 1.0);
    }`;

  const advectionFrag = `
    precision highp float; precision highp sampler2D;
    varying vec2 vUv; uniform sampler2D uVelocity; uniform sampler2D uSource;
    uniform vec2 texelSize; uniform vec2 dyeTexelSize; uniform float dt; uniform float dissipation;
    vec4 bilerp (sampler2D sam, vec2 uv, vec2 tsize) {
      vec2 st = uv / tsize - 0.5;
      vec2 iuv = floor(st); vec2 fuv = fract(st);
      vec4 a = texture2D(sam, (iuv + vec2(0.5, 0.5)) * tsize);
      vec4 b = texture2D(sam, (iuv + vec2(1.5, 0.5)) * tsize);
      vec4 c = texture2D(sam, (iuv + vec2(0.5, 1.5)) * tsize);
      vec4 d = texture2D(sam, (iuv + vec2(1.5, 1.5)) * tsize);
      return mix(mix(a, b, fuv.x), mix(c, d, fuv.x), fuv.y);
    }
    void main () {
    #ifdef MANUAL_FILTERING
      vec2 coord = vUv - dt * bilerp(uVelocity, vUv, texelSize).xy * texelSize;
      vec4 result = bilerp(uSource, coord, dyeTexelSize);
    #else
      vec2 coord = vUv - dt * texture2D(uVelocity, vUv).xy * texelSize;
      vec4 result = texture2D(uSource, coord);
    #endif
      float decay = 1.0 + dissipation * dt;
      gl_FragColor = result / decay;
    }`;

  const divergenceFrag = `
    precision mediump float; precision mediump sampler2D;
    varying highp vec2 vUv; varying highp vec2 vL; varying highp vec2 vR; varying highp vec2 vT; varying highp vec2 vB;
    uniform sampler2D uVelocity;
    void main () {
      float L = texture2D(uVelocity, vL).x;
      float R = texture2D(uVelocity, vR).x;
      float T = texture2D(uVelocity, vT).y;
      float B = texture2D(uVelocity, vB).y;
      vec2 C = texture2D(uVelocity, vUv).xy;
      if (vL.x < 0.0) { L = -C.x; }
      if (vR.x > 1.0) { R = -C.x; }
      if (vT.y > 1.0) { T = -C.y; }
      if (vB.y < 0.0) { B = -C.y; }
      float div = 0.5 * (R - L + T - B);
      gl_FragColor = vec4(div, 0.0, 0.0, 1.0);
    }`;

  const curlFrag = `
    precision mediump float; precision mediump sampler2D;
    varying highp vec2 vUv; varying highp vec2 vL; varying highp vec2 vR; varying highp vec2 vT; varying highp vec2 vB;
    uniform sampler2D uVelocity;
    void main () {
      float L = texture2D(uVelocity, vL).y;
      float R = texture2D(uVelocity, vR).y;
      float T = texture2D(uVelocity, vT).x;
      float B = texture2D(uVelocity, vB).x;
      float vorticity = R - L - T + B;
      gl_FragColor = vec4(0.5 * vorticity, 0.0, 0.0, 1.0);
    }`;

  const vorticityFrag = `
    precision highp float; precision highp sampler2D;
    varying vec2 vUv; varying vec2 vL; varying vec2 vR; varying vec2 vT; varying vec2 vB;
    uniform sampler2D uVelocity; uniform sampler2D uCurl; uniform float curl; uniform float dt;
    void main () {
      float L = texture2D(uCurl, vL).x;
      float R = texture2D(uCurl, vR).x;
      float T = texture2D(uCurl, vT).x;
      float B = texture2D(uCurl, vB).x;
      float C = texture2D(uCurl, vUv).x;
      vec2 force = 0.5 * vec2(abs(T) - abs(B), abs(R) - abs(L));
      force /= length(force) + 0.0001;
      force *= curl * C;
      force.y *= -1.0;
      vec2 velocity = texture2D(uVelocity, vUv).xy;
      velocity += force * dt;
      velocity = min(max(velocity, -1000.0), 1000.0);
      gl_FragColor = vec4(velocity, 0.0, 1.0);
    }`;

  const pressureFrag = `
    precision mediump float; precision mediump sampler2D;
    varying highp vec2 vUv; varying highp vec2 vL; varying highp vec2 vR; varying highp vec2 vT; varying highp vec2 vB;
    uniform sampler2D uPressure; uniform sampler2D uDivergence;
    void main () {
      float L = texture2D(uPressure, vL).x;
      float R = texture2D(uPressure, vR).x;
      float T = texture2D(uPressure, vT).x;
      float B = texture2D(uPressure, vB).x;
      float divergence = texture2D(uDivergence, vUv).x;
      float pressure = (L + R + B + T - divergence) * 0.25;
      gl_FragColor = vec4(pressure, 0.0, 0.0, 1.0);
    }`;

  const gradientSubtractFrag = `
    precision mediump float; precision mediump sampler2D;
    varying highp vec2 vUv; varying highp vec2 vL; varying highp vec2 vR; varying highp vec2 vT; varying highp vec2 vB;
    uniform sampler2D uPressure; uniform sampler2D uVelocity;
    void main () {
      float L = texture2D(uPressure, vL).x;
      float R = texture2D(uPressure, vR).x;
      float T = texture2D(uPressure, vT).x;
      float B = texture2D(uPressure, vB).x;
      vec2 velocity = texture2D(uVelocity, vUv).xy;
      velocity.xy -= vec2(R - L, T - B);
      gl_FragColor = vec4(velocity, 0.0, 1.0);
    }`;

  const displayFrag = `
    precision highp float; precision highp sampler2D;
    varying vec2 vUv; uniform sampler2D uTexture; uniform vec3 uInk;
    void main () {
      float d = texture2D(uTexture, vUv).r;
      float a = 1.0 - exp(-max(d, 0.0) * 3.4);   // 濃度→不透明度（黒く・不透明に）
      gl_FragColor = vec4(uInk * a, a);          // プリマルチプライ（紙に正しく合成）
    }`;

  const baseVS = compileShader(gl.VERTEX_SHADER, baseVertex);
  const copyProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, copyFrag));
  const clearProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, clearFrag));
  const splatProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, splatFrag));
  const advectionProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, advectionFrag, ext.supportLinearFiltering ? null : ['MANUAL_FILTERING']));
  const divergenceProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, divergenceFrag));
  const curlProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, curlFrag));
  const vorticityProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, vorticityFrag));
  const pressureProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, pressureFrag));
  const gradientProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, gradientSubtractFrag));
  const displayProg = createProgram(baseVS, compileShader(gl.FRAGMENT_SHADER, displayFrag));

  // -------------------- 描画バッファ --------------------
  const blit = (() => {
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, -1, 1, 1, 1, 1, -1]), gl.STATIC_DRAW);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array([0, 1, 2, 0, 2, 3]), gl.STATIC_DRAW);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    gl.enableVertexAttribArray(0);
    return (target, clear) => {
      if (!target) { gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight); gl.bindFramebuffer(gl.FRAMEBUFFER, null); }
      else { gl.viewport(0, 0, target.width, target.height); gl.bindFramebuffer(gl.FRAMEBUFFER, target.fbo); }
      if (clear) { gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT); }
      gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_SHORT, 0);
    };
  })();

  let dye, velocity, divergence, curlFBO, pressure;

  function createFBO(w, h, internalFormat, format, type, param) {
    gl.activeTexture(gl.TEXTURE0);
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, param);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, param);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, internalFormat, w, h, 0, format, type, null);
    const fbo = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
    gl.viewport(0, 0, w, h); gl.clear(gl.COLOR_BUFFER_BIT);
    const texelSizeX = 1.0 / w, texelSizeY = 1.0 / h;
    return {
      texture, fbo, width: w, height: h, texelSizeX, texelSizeY,
      attach(id) { gl.activeTexture(gl.TEXTURE0 + id); gl.bindTexture(gl.TEXTURE_2D, texture); return id; }
    };
  }
  function createDoubleFBO(w, h, internalFormat, format, type, param) {
    let fbo1 = createFBO(w, h, internalFormat, format, type, param);
    let fbo2 = createFBO(w, h, internalFormat, format, type, param);
    return {
      width: w, height: h, texelSizeX: fbo1.texelSizeX, texelSizeY: fbo1.texelSizeY,
      get read() { return fbo1; }, set read(v) { fbo1 = v; },
      get write() { return fbo2; }, set write(v) { fbo2 = v; },
      swap() { const t = fbo1; fbo1 = fbo2; fbo2 = t; }
    };
  }

  function getResolution(resolution) {
    let aspect = gl.drawingBufferWidth / gl.drawingBufferHeight;
    if (aspect < 1) aspect = 1.0 / aspect;
    const min = Math.round(resolution), max = Math.round(resolution * aspect);
    if (gl.drawingBufferWidth > gl.drawingBufferHeight) return { width: max, height: min };
    return { width: min, height: max };
  }

  function initFramebuffers() {
    const simRes = getResolution(config.SIM_RESOLUTION);
    const dyeRes = getResolution(config.DYE_RESOLUTION);
    const texType = ext.halfFloatTexType;
    const rgba = ext.formatRGBA, rg = ext.formatRG, r = ext.formatR;
    const filtering = ext.supportLinearFiltering ? gl.LINEAR : gl.NEAREST;
    gl.disable(gl.BLEND);

    dye = createDoubleFBO(dyeRes.width, dyeRes.height, rgba.internalFormat, rgba.format, texType, filtering);
    velocity = createDoubleFBO(simRes.width, simRes.height, rg.internalFormat, rg.format, texType, filtering);
    divergence = createFBO(simRes.width, simRes.height, r.internalFormat, r.format, texType, gl.NEAREST);
    curlFBO = createFBO(simRes.width, simRes.height, r.internalFormat, r.format, texType, gl.NEAREST);
    pressure = createDoubleFBO(simRes.width, simRes.height, r.internalFormat, r.format, texType, gl.NEAREST);
  }

  // -------------------- シミュレーション --------------------
  function step(dt) {
    gl.disable(gl.BLEND);

    gl.useProgram(curlProg.program);
    gl.uniform2f(curlProg.uniforms.texelSize, velocity.texelSizeX, velocity.texelSizeY);
    gl.uniform1i(curlProg.uniforms.uVelocity, velocity.read.attach(0));
    blit(curlFBO);

    gl.useProgram(vorticityProg.program);
    gl.uniform2f(vorticityProg.uniforms.texelSize, velocity.texelSizeX, velocity.texelSizeY);
    gl.uniform1i(vorticityProg.uniforms.uVelocity, velocity.read.attach(0));
    gl.uniform1i(vorticityProg.uniforms.uCurl, curlFBO.attach(1));
    gl.uniform1f(vorticityProg.uniforms.curl, config.CURL);
    gl.uniform1f(vorticityProg.uniforms.dt, dt);
    blit(velocity.write); velocity.swap();

    gl.useProgram(divergenceProg.program);
    gl.uniform2f(divergenceProg.uniforms.texelSize, velocity.texelSizeX, velocity.texelSizeY);
    gl.uniform1i(divergenceProg.uniforms.uVelocity, velocity.read.attach(0));
    blit(divergence);

    gl.useProgram(clearProg.program);
    gl.uniform1i(clearProg.uniforms.uTexture, pressure.read.attach(0));
    gl.uniform1f(clearProg.uniforms.value, config.PRESSURE);
    blit(pressure.write); pressure.swap();

    gl.useProgram(pressureProg.program);
    gl.uniform2f(pressureProg.uniforms.texelSize, velocity.texelSizeX, velocity.texelSizeY);
    gl.uniform1i(pressureProg.uniforms.uDivergence, divergence.attach(0));
    for (let i = 0; i < config.PRESSURE_ITERATIONS; i++) {
      gl.uniform1i(pressureProg.uniforms.uPressure, pressure.read.attach(1));
      blit(pressure.write); pressure.swap();
    }

    gl.useProgram(gradientProg.program);
    gl.uniform2f(gradientProg.uniforms.texelSize, velocity.texelSizeX, velocity.texelSizeY);
    gl.uniform1i(gradientProg.uniforms.uPressure, pressure.read.attach(0));
    gl.uniform1i(gradientProg.uniforms.uVelocity, velocity.read.attach(1));
    blit(velocity.write); velocity.swap();

    gl.useProgram(advectionProg.program);
    gl.uniform2f(advectionProg.uniforms.texelSize, velocity.texelSizeX, velocity.texelSizeY);
    if (!ext.supportLinearFiltering) gl.uniform2f(advectionProg.uniforms.dyeTexelSize, velocity.texelSizeX, velocity.texelSizeY);
    gl.uniform1i(advectionProg.uniforms.uVelocity, velocity.read.attach(0));
    gl.uniform1i(advectionProg.uniforms.uSource, velocity.read.attach(0));
    gl.uniform1f(advectionProg.uniforms.dt, dt);
    gl.uniform1f(advectionProg.uniforms.dissipation, config.VELOCITY_DISSIPATION);
    blit(velocity.write); velocity.swap();

    gl.uniform1i(advectionProg.uniforms.uVelocity, velocity.read.attach(0));
    gl.uniform1i(advectionProg.uniforms.uSource, dye.read.attach(1));
    if (!ext.supportLinearFiltering) gl.uniform2f(advectionProg.uniforms.dyeTexelSize, dye.texelSizeX, dye.texelSizeY);
    gl.uniform1f(advectionProg.uniforms.dissipation, config.DENSITY_DISSIPATION);
    blit(dye.write); dye.swap();
  }

  function render() {
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);   // ストレートアルファで紙に合成
    gl.useProgram(displayProg.program);
    gl.uniform1i(displayProg.uniforms.uTexture, dye.read.attach(0));
    gl.uniform3f(displayProg.uniforms.uInk, INK[0], INK[1], INK[2]);
    blit(null);
  }

  function splat(x, y, dx, dy, amount) {
    gl.disable(gl.BLEND);
    gl.useProgram(splatProg.program);
    gl.uniform1i(splatProg.uniforms.uTarget, velocity.read.attach(0));
    gl.uniform1f(splatProg.uniforms.aspectRatio, canvas.width / canvas.height);
    gl.uniform2f(splatProg.uniforms.point, x, y);
    gl.uniform3f(splatProg.uniforms.color, dx, dy, 0.0);
    gl.uniform1f(splatProg.uniforms.radius, correctRadius(config.SPLAT_RADIUS / 100.0));
    blit(velocity.write); velocity.swap();

    gl.uniform1i(splatProg.uniforms.uTarget, dye.read.attach(0));
    const s = amount * config.INK_STRENGTH;
    gl.uniform3f(splatProg.uniforms.color, s, s, s);
    blit(dye.write); dye.swap();
  }
  function correctRadius(radius) {
    const aspect = canvas.width / canvas.height;
    if (aspect > 1) radius *= aspect;
    return radius;
  }

  // -------------------- サイズ --------------------
  function scaleByPixelRatio(v) { return Math.floor(v * Math.min(window.devicePixelRatio || 1, 2)); }
  function resizeCanvas() {
    const w = scaleByPixelRatio(canvas.clientWidth);
    const h = scaleByPixelRatio(canvas.clientHeight);
    if (w > 0 && h > 0 && (canvas.width !== w || canvas.height !== h)) {
      canvas.width = w; canvas.height = h; return true;
    }
    return false;
  }

  // -------------------- 入力（指/マウス＋ジェスチャー） --------------------
  // ポインタ：画面をなぞると墨が生まれ、動きの方向に流れる
  let lastPX = null, lastPY = null;
  const trail = [];   // 直近の軌跡（bloom用）
  function pointerMove(clientX, clientY) {
    const x = clientX / window.innerWidth;
    const y = 1.0 - clientY / window.innerHeight;
    trail.push({ x: x, y: y, t: performance.now() });
    if (trail.length > 32) trail.shift();
    if (lastPX !== null) {
      const dx = (x - lastPX) * config.SPLAT_FORCE;
      const dy = (y - lastPY) * config.SPLAT_FORCE;
      const moved = Math.hypot(dx, dy);
      if (moved > 0.5) splat(x, y, dx, dy, Math.min(1.0, 0.4 + moved / config.SPLAT_FORCE * 6.0));
    }
    lastPX = x; lastPY = y;
  }
  window.addEventListener('mousemove', e => pointerMove(e.clientX, e.clientY), { passive: true });
  window.addEventListener('touchmove', e => {
    for (let i = 0; i < e.touches.length; i++) pointerMove(e.touches[i].clientX, e.touches[i].clientY);
  }, { passive: true });
  window.addEventListener('mouseleave', () => { lastPX = lastPY = null; });

  // ※ 通常は墨は指/マウスの動きからだけ生まれる（最初の立ち上がり無し）。

  // 画面2へ移る時：直近の指/マウスの軌跡に沿ってだけ、墨が大きく咲く
  // （触っていない場所からは出さない。軌跡が無ければ画面下中央から静かに立ち上る）
  function bloom() {
    const now = performance.now();
    let pts = trail.filter(p => now - p.t < 1400);
    if (pts.length < 2) pts = [{x:0.5, y:0.10}, {x:0.5, y:0.26}, {x:0.5, y:0.42}];
    // 軌跡から均等に最大8点を用意
    const N = Math.min(8, pts.length);
    const items = [];
    for (let i = 0; i < N; i++) {
      const idx = Math.floor(i * (pts.length - 1) / Math.max(1, N - 1));
      const p = pts[idx];
      const q = pts[Math.min(idx + 1, pts.length - 1)];
      items.push({ x: p.x, y: p.y, dx: (q.x - p.x) * 2600, dy: (q.y - p.y) * 2600 });
    }
    // フレーム同期で2発ずつ描く（1フレームに負荷を集中させない＝カクつかない）
    let i = 0;
    function pump() {
      for (let k = 0; k < 2 && i < items.length; k++, i++) {
        const it = items[i];
        const r0 = config.SPLAT_RADIUS;
        config.SPLAT_RADIUS = 0.5;                 // 咲く時だけ大きな滴に
        splat(it.x, it.y, it.dx, it.dy, 2.0);
        config.SPLAT_RADIUS = r0;
      }
      if (i < items.length) requestAnimationFrame(pump);
    }
    requestAnimationFrame(pump);
  }
  // 画面2に居る間は墨を消えにくくして“定着”させる（動きは自然に収まり静止する）
  // 離れたら通常の消え方に戻し、ゆっくり薄れて消える
  const NORMAL_DISSIPATION = config.DENSITY_DISSIPATION;
  function hold(on) {
    config.DENSITY_DISSIPATION = on ? 0.04 : NORMAL_DISSIPATION;
  }
  window.InkFluid = { bloom: bloom, hold: hold };

  // -------------------- ループ --------------------
  let lastTime = performance.now();
  function update() {
    const now = performance.now();
    let dt = (now - lastTime) / 1000; dt = Math.min(dt, 0.0166); lastTime = now;
    if (resizeCanvas()) initFramebuffers();
    if (!document.hidden) { step(dt); render(); }
    requestAnimationFrame(update);
  }

  resizeCanvas();
  initFramebuffers();
  window.addEventListener('resize', () => { if (resizeCanvas()) initFramebuffers(); });
  requestAnimationFrame(update);
})();
