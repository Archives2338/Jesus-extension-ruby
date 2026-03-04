module JesusDeveloper
  module MultiPush

    DIALOG_WIDTH  = 360
    DIALOG_HEIGHT = 360

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
      # JS envía: sketchup.ejecutar_extrusion(JSON.stringify({modo, distancia, eje}))
      # Ruby recibe el string, lo parsea y enruta al modo correcto.
      # Equivalente a: ipcMain.on('ejecutar_extrusion', (e, params) => { ... })
      @dialog.add_action_callback('ejecutar_extrusion') do |_ctx, params_json|
        params    = JSON.parse(params_json)
        resultado = self.procesar_geometria(params)
        @dialog.execute_script("mostrarResultado(#{resultado.to_json})")
      end

      # Limpia la referencia al cerrar para que el singleton funcione bien
      @dialog.set_on_closed { @dialog = nil }

      @dialog.show
    end

    # ─────────────────────────────────────────────────────────────────────────
    # procesar_geometria(params)  — Router de modos
    #
    #   Recibe un Hash con:
    #     'modo'      → 'normal' | 'vector'
    #     'distancia' → Float
    #     'eje'       → 'x' | 'y' | 'z'  (solo en modo vector)
    #
    #   Delega al modo correcto. Equivale al switch/case de un Express router.
    # ─────────────────────────────────────────────────────────────────────────
    def self.procesar_geometria(params)
      case params['modo']
      when 'vector' then self.modo_vector(params)
      else               self.modo_normal(params)
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # _guards(cara, idx)  — Validaciones comunes a todos los modos
    #   Retorna String con el motivo de omisión, o nil si la cara es válida.
    # ─────────────────────────────────────────────────────────────────────────
    def self._guards(cara, idx)
      return 'eliminada por operación previa'      if cara.deleted?
      return "área ≈ 0 (#{cara.area.round(8)} u²)" if cara.area < 1e-6
      n = cara.normal
      return 'normal inválido'                     unless n.valid? && n.length > 1e-10
      nil
    end

    # ─────────────────────────────────────────────────────────────────────────
    # _log_resumen — Imprime tabla de resumen en la Ruby Console
    # ─────────────────────────────────────────────────────────────────────────
    def self._log_resumen(modo, distancia, total, extruidas, omitidas, limpiezas, errores)
      puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
      puts "[Jesus Multi-Push] #{modo} · #{distancia} unidades"
      puts "  Total seleccionadas : #{total}"
      puts "  ✅  Extruidas        : #{extruidas}"
      puts "  ⏭   Omitidas         : #{omitidas}"
      puts "  🧹  Limpiezas        : #{limpiezas}"
      puts "  ⚠   Errores por cara : #{errores.length}"
      errores.each { |err| puts "       → #{err}" }
      puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    end

    # ─────────────────────────────────────────────────────────────────────────
    # modo_normal(params)  — MVP1: cada cara sigue su propio vector normal
    # ─────────────────────────────────────────────────────────────────────────
    def self.modo_normal(params)
      distancia = params['distancia'].to_f
      model     = Sketchup.active_model
      faces     = model.selection.grep(Sketchup::Face).to_a

      if faces.empty?
        UI.messagebox('Selecciona al menos una cara antes de extruir.', MB_OK)
        return { ok: false, mensaje: 'Sin caras seleccionadas', extruidas: 0 }
      end

      extruidas, omitidas, limpiezas, errores = 0, 0, 0, []

      model.start_operation('Jesus Multi-Push · Normal', true)
      begin
        faces.each_with_index do |cara, idx|
          begin
            if (motivo = _guards(cara, idx))
              omitidas += 1
              puts "[Jesus Multi-Push] Cara ##{idx + 1}: #{motivo}, omitida."
              next
            end
            cara.pushpull(distancia, true)
            extruidas += 1
            if !cara.deleted? && cara.area < 1e-6
              cara.erase!
              limpiezas += 1
            end
          rescue StandardError => e
            errores << "Cara ##{idx + 1}: #{e.message}"
            puts "[Jesus Multi-Push] ⚠  Error en cara ##{idx + 1}: #{e.message}"
          end
        end
        model.commit_operation
        _log_resumen('Normal', distancia, faces.length, extruidas, omitidas, limpiezas, errores)
        resumen = errores.empty? ? "#{extruidas} cara(s) extruida(s)" : "#{extruidas} extruida(s), #{errores.length} error(es)"
        { ok: true, mensaje: resumen, extruidas: extruidas, omitidas: omitidas }
      rescue StandardError => e
        model.abort_operation
        puts "[Jesus Multi-Push] 🔴 ERROR CRÍTICO: #{e.message}"
        UI.messagebox("Error crítico:\n#{e.message}\n\nCambios revertidos.", MB_OK)
        { ok: false, mensaje: "Error crítico: #{e.message}", extruidas: 0 }
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # modo_vector(params)  — MVP2: todas las caras se empujan en un eje global
    #
    #   Matemática con producto punto:
    #   pushpull siempre mueve ALONG face.normal. Para que el desplazamiento
    #   real en la dirección del vector global sea igual a `distancia`:
    #
    #       distancia_real = distancia / dot(face.normal, vector_global)
    #
    #   · dot ≈ 0  → cara perpendicular al eje → imposible proyectar → omitir
    #   · dot < 0  → normal apunta opuesto al eje → distancia_real negativa
    #                → pushpull va en -normal → resultado correcto ✓
    # ─────────────────────────────────────────────────────────────────────────
    def self.modo_vector(params)
      distancia = params['distancia'].to_f
      eje       = params['eje'] || 'z'
      model     = Sketchup.active_model
      faces     = model.selection.grep(Sketchup::Face).to_a

      if faces.empty?
        UI.messagebox('Selecciona al menos una cara antes de extruir.', MB_OK)
        return { ok: false, mensaje: 'Sin caras seleccionadas', extruidas: 0 }
      end

      vector_global = case eje
                      when 'x' then Geom::Vector3d.new(1, 0, 0)
                      when 'y' then Geom::Vector3d.new(0, 1, 0)
                      else          Geom::Vector3d.new(0, 0, 1)  # 'z' por defecto
                      end

      extruidas, omitidas, limpiezas, errores = 0, 0, 0, []

      model.start_operation("Jesus Multi-Push · Vector #{eje.upcase}", true)
      begin
        faces.each_with_index do |cara, idx|
          begin
            if (motivo = _guards(cara, idx))
              omitidas += 1
              puts "[Jesus Multi-Push] Cara ##{idx + 1}: #{motivo}, omitida."
              next
            end

            dot = cara.normal.dot(vector_global)

            if dot.abs < 0.01
              omitidas += 1
              puts "[Jesus Multi-Push] Cara ##{idx + 1}: perpendicular al eje #{eje.upcase} (dot=#{dot.round(4)}), omitida."
              next
            end

            cara.pushpull(distancia / dot, true)
            extruidas += 1

            if !cara.deleted? && cara.area < 1e-6
              cara.erase!
              limpiezas += 1
            end
          rescue StandardError => e
            errores << "Cara ##{idx + 1}: #{e.message}"
            puts "[Jesus Multi-Push] ⚠  Error en cara ##{idx + 1}: #{e.message}"
          end
        end
        model.commit_operation
        _log_resumen("Vector #{eje.upcase}", distancia, faces.length, extruidas, omitidas, limpiezas, errores)
        resumen = errores.empty? ? "#{extruidas} cara(s) → eje #{eje.upcase}" : "#{extruidas} extruida(s), #{errores.length} error(es)"
        { ok: true, mensaje: resumen, extruidas: extruidas, omitidas: omitidas }
      rescue StandardError => e
        model.abort_operation
        puts "[Jesus Multi-Push] 🔴 ERROR CRÍTICO: #{e.message}"
        UI.messagebox("Error crítico:\n#{e.message}\n\nCambios revertidos.", MB_OK)
        { ok: false, mensaje: "Error crítico: #{e.message}", extruidas: 0 }
      end
    end

  end # MultiPush
end # JesusDeveloper