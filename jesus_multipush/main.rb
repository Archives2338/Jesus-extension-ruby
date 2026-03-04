module JesusDeveloper
  module MultiPush

    DIALOG_WIDTH  = 360
    DIALOG_HEIGHT = 260

    # ─────────────────────────────────────────────────────────────────────────
    # show_dialog
    #   • Patrón singleton: si el diálogo ya existe y está visible lo trae al
    #     frente en vez de crear una segunda instancia (igual que en Node
    #     harías Window.focus() en lugar de new BrowserWindow()).
    # ─────────────────────────────────────────────────────────────────────────
    def self.show_dialog
      if @dialog&.visible?
        @dialog.bring_to_front
        return
      end

      html_path = File.join(__dir__, 'ui', 'index.html')

      unless File.exist?(html_path)
        UI.messagebox("No se encontró ui/index.html:\n#{html_path}", MB_OK)
        return
      end

      options = {
        dialog_title:    'Jesus Multi-Push',
        scrollable:      false,
        resizable:       false,
        width:           DIALOG_WIDTH,
        height:          DIALOG_HEIGHT,
        style:           UI::HtmlDialog::STYLE_DIALOG
      }

      @dialog = UI::HtmlDialog.new(options)
      @dialog.set_file(html_path)

      # ── Centrado en pantalla ───────────────────────────────────────────────
      # SketchUp no expone fácilmente las dimensiones del monitor, por lo que
      # usamos 1920×1080 como referencia base y escalamos con screen_scaling_factor.
      scale        = UI.screen_scaling_factor rescue 1.0
      screen_w     = (1920 / scale).to_i
      screen_h     = (1080 / scale).to_i
      left         = ((screen_w - DIALOG_WIDTH)  / 2).to_i
      top          = ((screen_h - DIALOG_HEIGHT) / 2).to_i
      @dialog.set_position(left, top)

      # ── Bridge Ruby ↔ JS ──────────────────────────────────────────────────
      # Equivale a ipcMain.on('ejecutar_extrusion', (event, distancia) => {...})
      @dialog.add_action_callback('ejecutar_extrusion') do |_ctx, distancia|
        resultado = self.procesar_geometria(distancia.to_f)
        # Devuelve feedback al frontend via sketchup.callbackName en JS
        @dialog.execute_script("mostrarResultado(#{resultado.to_json})")
      end

      # Limpia la referencia al cerrar para que el singleton funcione bien
      @dialog.set_on_closed { @dialog = nil }

      @dialog.show
    end

    # ─────────────────────────────────────────────────────────────────────────
    # procesar_geometria(distancia)
    #
    #   Lógica central del Multi-Push:
    #   1. Filtra la selección a solo Sketchup::Face.
    #   2. Por cada cara, obtiene su vector normal (face.normal) que siempre
    #      apunta hacia el lado "exterior" de la cara en su contexto local.
    #   3. Llama pushpull(distancia, true):
    #      - distancia > 0  → extrusión en sentido del normal (hacia afuera)
    #      - distancia < 0  → intrusión (hacia adentro)
    #      - true           → genera una nueva cara base (comportamiento JointPushPull)
    #
    #   Devuelve un Hash con info para el callback JS.
    # ─────────────────────────────────────────────────────────────────────────
    def self.procesar_geometria(distancia)
      model = Sketchup.active_model

      # Snapshot a Array fijo ANTES de operar.
      # Durante el pushpull la colección de la selección puede mutar (SketchUp
      # puede agregar/quitar entidades automáticamente), así que trabajamos
      # sobre una copia congelada, igual que harías [...arr] en JS.
      faces = model.selection.grep(Sketchup::Face).to_a

      if faces.empty?
        UI.messagebox('Selecciona al menos una cara antes de extruir.', MB_OK)
        return { ok: false, mensaje: 'Sin caras seleccionadas', extruidas: 0 }
      end

      extruidas = 0
      omitidas  = 0
      limpiezas = 0
      errores   = []   # Array de strings con detalle por cara fallida

      # ── start_operation(nombre, disable_ui, add_to_undo, transparent) ─────
      # · disable_ui = true  → congela la UI mientras opera (más rápido)
      # · add_to_undo = true → toda la operación queda como UN SOLO paso en
      #   el historial; el usuario deshace todo con un solo Cmd+Z.
      model.start_operation('Jesus Multi-Push', true)

      begin
        faces.each_with_index do |cara, idx|
          begin
            # ── Guard 1: cara ya eliminada ─────────────────────────────────
            # El pushpull de una cara adyacente puede haber borrado esta cara
            # como efecto secundario de la fusión de geometría.
            if cara.deleted?
              omitidas += 1
              puts "[Jesus Multi-Push] Cara ##{idx + 1}: eliminada por operación previa, omitida."
              next
            end

            # ── Guard 2: área cero o degenerada ───────────────────────────
            # Artefactos de modelado producen caras con área < 1e-6 que
            # harían crash en pushpull.
            if cara.area < 1e-6
              omitidas += 1
              puts "[Jesus Multi-Push] Cara ##{idx + 1}: área ≈ 0 (#{cara.area.round(8)} u²), omitida."
              next
            end

            # ── Guard 3: normal inválido ───────────────────────────────────
            # face.normal devuelve el Vector3d perpendicular a la cara,
            # orientado hacia el lado "frontal" (exterior por convención de SU).
            # Una cara degenerada puede devolver un vector de longitud 0.
            normal = cara.normal
            unless normal.valid? && normal.length > 1e-10
              omitidas += 1
              puts "[Jesus Multi-Push] Cara ##{idx + 1}: normal inválido, omitida."
              next
            end

            # ── Extrusión con vector normal propio ────────────────────────
            # pushpull(distancia, create_face):
            #   · El signo de distancia controla la dirección:
            #       distancia > 0 → extrusión hacia afuera (sentido del normal)
            #       distancia < 0 → intrusión hacia adentro (sentido inverso)
            #   · create_face = true → siempre genera una cara base nueva en
            #     el origen, replicando el comportamiento de JointPushPull.
            #   · Cada cara usa SU PROPIO normal local, por eso funciona
            #     correctamente aunque las caras apunten en distintas
            #     direcciones (ej: techo + paredes seleccionados a la vez).
            cara.pushpull(distancia, true)
            extruidas += 1

            # ── Limpieza de geometría ─────────────────────────────────────
            # Tras el pushpull, la cara original "viaja" al extremo del sólido.
            # En casos degenerados (distancia = 0 o cara coplanar con otra)
            # puede quedar como residuo de área ≈ 0 sin referencias útiles.
            # Lo borramos para mantener el modelo limpio.
            if !cara.deleted? && cara.area < 1e-6
              cara.erase!
              limpiezas += 1
              puts "[Jesus Multi-Push] Cara ##{idx + 1}: residuo de área cero eliminado tras extrusión."
            end

          rescue StandardError => e
            # Error aislado por cara: lo registramos y continuamos con las
            # demás en lugar de abortar toda la operación.
            errores << "Cara ##{idx + 1}: #{e.message}"
            puts "[Jesus Multi-Push] ⚠  Error en cara ##{idx + 1}: #{e.message}"
          end
        end

        model.commit_operation

        # ── Resumen detallado en Ruby Console ─────────────────────────────
        puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        puts "[Jesus Multi-Push] Operación completada · #{distancia} unidades"
        puts "  Total seleccionadas : #{faces.length}"
        puts "  ✅  Extruidas        : #{extruidas}"
        puts "  ⏭   Omitidas         : #{omitidas}"
        puts "  🧹  Limpiezas        : #{limpiezas}"
        puts "  ⚠   Errores por cara : #{errores.length}"
        errores.each { |err| puts "       → #{err}" }
        puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

        resumen = errores.empty? \
          ? "#{extruidas} cara(s) extruida(s)" \
          : "#{extruidas} extruida(s), #{errores.length} error(es)"

        { ok: true, mensaje: resumen, extruidas: extruidas,
          omitidas: omitidas, limpiezas: limpiezas, errores: errores }

      rescue StandardError => e
        # Error crítico: revertimos TODO con abort_operation.
        # El historial de Undo no registra nada — el modelo queda intacto.
        model.abort_operation
        puts "[Jesus Multi-Push] 🔴 ERROR CRÍTICO — operación revertida: #{e.message}"
        UI.messagebox(
          "Error crítico:\n#{e.message}\n\nTodos los cambios fueron revertidos.\n(Undo sigue disponible para operaciones previas)",
          MB_OK
        )
        { ok: false, mensaje: "Error crítico: #{e.message}", extruidas: 0 }
      end
    end

  end # MultiPush
end # JesusDeveloper