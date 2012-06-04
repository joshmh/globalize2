module Globalize
  class MigrationError < StandardError; end
  class MigrationMissingTranslatedField < MigrationError; end
  class BadMigrationFieldType < MigrationError; end

  module ActiveRecord
    autoload :Adapter,      'globalize/active_record/adapter'
    autoload :Attributes,   'globalize/active_record/attributes'
    autoload :Migration,    'globalize/active_record/migration'

    def self.included(base)
      base.extend ActMacro
    end

    class << self
      def build_translation_class(target, options)
        options[:table_name] ||= "#{target.table_name.singularize}_translations"

        klass = target.const_defined?(:Translation) ?
          target.const_get(:Translation) :
          target.const_set(:Translation, Class.new(::ActiveRecord::Base))

        klass.class_eval do
          set_table_name(options[:table_name])
          belongs_to target.base_class.name.underscore.gsub('/', '_')
          def locale; read_attribute(:locale).to_sym; end
          def locale=(locale); write_attribute(:locale, locale.to_s); end
        end

        klass
      end
    end

    module ActMacro
      def locale
        (defined?(@@locale) && @@locale)
      end

      def locale=(locale)
        @@locale = locale
      end

      def translates(*attr_names)
        return if translates?
        options = attr_names.extract_options!

        class_inheritable_accessor :translation_class, :translated_attribute_names
        class_inheritable_writer :required_attributes
        self.translation_class = ActiveRecord.build_translation_class(self, options)
        self.translated_attribute_names = attr_names.map(&:to_sym)

        include InstanceMethods
        extend  ClassMethods, Migration

        after_save :save_translations!
        has_many :translations, :class_name  => translation_class.name,
                                :foreign_key => self.base_class.name.foreign_key,
                                :dependent   => :delete_all,
                                :extend      => HasManyExtensions

        named_scope :with_translations, lambda { |locale|
          conditions = required_attributes.map do |attribute|
            "#{quoted_translation_table_name}.#{attribute} IS NOT NULL"
          end
          conditions << "#{quoted_translation_table_name}.locale = ?"
          { :include => :translations, :conditions => [conditions.join(' AND '), locale] }
        }

        attr_names.each { |attr_name| translated_attr_accessor(attr_name) }
      end

      def translates?
        included_modules.include?(InstanceMethods)
      end
    end

    module HasManyExtensions
      def by_locale(locale)
        first(:conditions => { :locale => locale.to_s })
      end

      def by_locales(locales)
        all(:conditions => { :locale => locales.map(&:to_s) })
      end
    end

    module ClassMethods
      delegate :set_translation_table_name, :to => :translation_class

      def with_locale(locale)
        previous_locale, self.locale = self.locale, locale
        result = yield
        self.locale = previous_locale
        result
      end

      def translation_table_name
        translation_class.table_name
      end

      def quoted_translation_table_name
        translation_class.quoted_table_name
      end

      def required_attributes
        @required_attributes ||= reflect_on_all_validations.select do |validation|
          validation.macro == :validates_presence_of && translated_attribute_names.include?(validation.name)
        end.map(&:name)
      end

      def respond_to?(method, *args, &block)
        !!dynamic_finder(method) || super
      end

      def method_missing(method, *args)
        match = dynamic_finder(method)

        if match
          has_translated_attrs = match.attribute_names.any? do |attribute_name|
            translated_attribute_names.include?(attribute_name.to_sym)
          end
          
          return find_by_dynamic_match(match, args) if has_translated_attrs
        end

        super
      end

      protected

        def dynamic_finder(method)
          match = ::ActiveRecord::DynamicFinderMatch.match(method)
          match if match && match.finder?
        end

        def find_by_dynamic_match(match, values)
          conditions = []
          match.attribute_names.each_with_index do |attribute_name, i|
            break if i >= values.size

            if translated_attribute_names.include?(attribute_name.to_sym)
              field = translated_attr_name(attribute_name)
            else
              field = untranslated_attr_name(attribute_name)
            end

            conditions << "#{field} = ?"
          end

          values.map!(&:to_param)

          conditions << "#{translated_attr_name('locale')} IN (?)"
          values << Globalize.fallbacks(locale || I18n.locale).map(&:to_s)

          result = find(match.finder, 
            :readonly => false,
            :joins => :translations,
            :conditions => values.unshift(conditions.join(" AND ")))

          if match.bang? && !result
            raise(::ActiveRecord::RecordNotFound, "Couldn\'t find #{name} with provided values of #{match.attribute_names.join(', ')}")
          end

          result
        end

        def translated_attr_accessor(name)
          define_method "#{name}=", lambda { |value|
            globalize.write(self.class.locale || I18n.locale, name, value)
            self[name] = value
          }

          define_method name, lambda { |*args|
            globalize.fetch(args.first || self.class.locale || I18n.locale, name)
          }

          define_method "#{name}?", lambda { |*args|
            globalize.fetch(args.first || self.class.locale || I18n.locale, name).present?
          }

          alias_method "#{name}_before_type_cast", name
        end

        def translated_attr_name(name)
          "#{translation_class.table_name}.#{name}"
        end

        def untranslated_attr_name(name)
          "#{table_name}.#{name}"
        end
    end

    module InstanceMethods
      def globalize
        @globalize ||= Adapter.new self
      end

      def attributes
        self.attribute_names.inject({}) do |attrs, name|
          if @attributes.include? name.to_s
            attrs[name] = read_attribute(name)
          else
            attrs[name] = (globalize.fetch(I18n.locale, name) rescue nil)
          end
          attrs
        end
      end

      def attributes=(attributes, *args)
        if attributes.respond_to?(:delete) && locale = attributes.delete(:locale)
          self.class.with_locale(locale) { super }
        else
          super
        end
      end

      def attribute_names
        translated_attribute_names.map(&:to_s) + super
      end

      def available_locales
        translations.scoped(:select => 'DISTINCT locale').map(&:locale)
      end

      def translated_locales
        translations.map(&:locale)
      end

      def translated_attributes
        translated_attribute_names.inject({}) do |attributes, name|
          attributes.merge(name => send(name))
        end
      end

      def set_translations(options)
        options.keys.each do |locale|
          translation = translations.find_by_locale(locale.to_s) ||
            translations.build(:locale => locale.to_s)
          translation.update_attributes!(options[locale])
        end
      end

      def reload(*args)
        translated_attribute_names.each { |name| @attributes.delete(name.to_s) }
        globalize.reset
        super(*args)
      end

      protected

        def save_translations!
          globalize.save_translations!
        end
    end
  end
end
