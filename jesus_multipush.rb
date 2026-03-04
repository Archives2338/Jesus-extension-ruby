require 'sketchup.rb'
require 'extensions.rb'

module JesusDeveloper
  module MultiPush
    unless file_loaded?(__FILE__)
      ex = SketchupExtension.new('Jesus Multi-Push', 'jesus_multipush/main')
      ex.description = 'Extrusión múltiple de caras - MVP1'
      ex.version     = '1.0.0'
      ex.creator     = 'Jesus Alejandro Rojas Ponce' #
      Sketchup.register_extension(ex, true)
      file_loaded(__FILE__)
    end
  end
end