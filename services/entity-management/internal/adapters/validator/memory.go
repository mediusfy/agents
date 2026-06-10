package validator

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"sync"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
)

const tracerName = "entity-management.validator"

type compiledSchema struct {
	Schema   *domain.EntitySchema
	Patterns map[string]*regexp.Regexp
}

type MemoryValidator struct {
	mu     sync.RWMutex
	cache  map[string]*compiledSchema
	repo   domain.SchemaRepository
	logger *slog.Logger
	tracer trace.Tracer
}

func NewMemoryValidator(repo domain.SchemaRepository, logger *slog.Logger) *MemoryValidator {
	return &MemoryValidator{
		cache:  make(map[string]*compiledSchema),
		repo:   repo,
		logger: logger.With("adapter", "validator.MemoryValidator"),
		tracer: otel.Tracer(tracerName),
	}
}

func (v *MemoryValidator) CompileSchema(ctx context.Context, schema *domain.EntitySchema) error {
	ctx, span := v.tracer.Start(ctx, "validator.MemoryValidator.CompileSchema",
		trace.WithAttributes(
			attribute.String("schema_id", schema.ID),
			attribute.Int("attr_count", len(schema.Attributes)),
		))
	defer span.End()

	cs := &compiledSchema{
		Schema:   schema,
		Patterns: make(map[string]*regexp.Regexp, len(schema.Attributes)),
	}

	for _, attr := range schema.Attributes {
		if attr.Constraint != nil && attr.Constraint.Pattern != "" {
			re, err := regexp.Compile(attr.Constraint.Pattern)
			if err != nil {
				return fmt.Errorf("compile pattern for %q: %w", attr.Name, err)
			}
			cs.Patterns[attr.Name] = re
		}
	}

	v.mu.Lock()
	v.cache[schema.ID] = cs
	v.mu.Unlock()
	return nil
}

func (v *MemoryValidator) Validate(ctx context.Context, schemaID string, attrs map[string]any) error {
	ctx, span := v.tracer.Start(ctx, "validator.MemoryValidator.Validate",
		trace.WithAttributes(
			attribute.String("schema_id", schemaID),
			attribute.Int("attr_count", len(attrs)),
		))
	defer span.End()

	cs, err := v.getCompiled(ctx, schemaID)
	if err != nil {
		return err
	}

	schema := cs.Schema
	for _, attr := range schema.Attributes {
		val, ok := attrs[attr.Name]
		if attr.Required && !ok {
			return fmt.Errorf("%w: %q is required", domain.ErrMissingRequiredAttr, attr.Name)
		}
		if !ok {
			continue
		}

		if err := validateAttributeType(attr.Type, val); err != nil {
			return fmt.Errorf("%s: %w", attr.Name, err)
		}

		if attr.Constraint != nil {
			if err := validateConstraint(attr, val, cs.Patterns[attr.Name]); err != nil {
				return fmt.Errorf("%s: %w", attr.Name, err)
			}
		}
	}
	return nil
}

func (v *MemoryValidator) Invalidate(ctx context.Context, schemaID string) {
	v.mu.Lock()
	delete(v.cache, schemaID)
	v.mu.Unlock()
}

func (v *MemoryValidator) getCompiled(ctx context.Context, schemaID string) (*compiledSchema, error) {
	v.mu.RLock()
	cs, ok := v.cache[schemaID]
	v.mu.RUnlock()
	if ok {
		return cs, nil
	}

	schema, err := v.repo.FindByID(ctx, schemaID)
	if err != nil {
		return nil, fmt.Errorf("validator load schema: %w", err)
	}
	if err := v.CompileSchema(ctx, schema); err != nil {
		return nil, err
	}

	v.mu.RLock()
	cs = v.cache[schemaID]
	v.mu.RUnlock()
	return cs, nil
}

func validateAttributeType(typ domain.AttributeType, val any) error {
	switch typ {
	case domain.AttributeTypeString:
		if _, ok := val.(string); !ok {
			return fmt.Errorf("%w: expected string, got %T", domain.ErrValidationFailed, val)
		}
	case domain.AttributeTypeInt:
		switch val.(type) {
		case float64, int, int64:
		default:
			return fmt.Errorf("%w: expected int, got %T", domain.ErrValidationFailed, val)
		}
	case domain.AttributeTypeBool:
		if _, ok := val.(bool); !ok {
			return fmt.Errorf("%w: expected bool, got %T", domain.ErrValidationFailed, val)
		}
	case domain.AttributeTypeJSON:
		return nil
	case domain.AttributeTypeEnum:
		if _, ok := val.(string); !ok {
			return fmt.Errorf("%w: expected string for enum, got %T", domain.ErrValidationFailed, val)
		}
	default:
		return fmt.Errorf("%w: unknown type %q", domain.ErrValidationFailed, typ)
	}
	return nil
}

func validateConstraint(attr domain.AttributeDefinition, val any, pattern *regexp.Regexp) error {
	c := attr.Constraint
	if c == nil {
		return nil
	}

	switch attr.Type {
	case domain.AttributeTypeString:
		s, ok := val.(string)
		if !ok {
			return nil
		}
		if c.Min != nil && len(s) < *c.Min {
			return fmt.Errorf("%w: min length %d", domain.ErrValidationFailed, *c.Min)
		}
		if c.Max != nil && len(s) > *c.Max {
			return fmt.Errorf("%w: max length %d", domain.ErrValidationFailed, *c.Max)
		}
		if pattern != nil && !pattern.MatchString(s) {
			return fmt.Errorf("%w: pattern mismatch", domain.ErrValidationFailed)
		}

	case domain.AttributeTypeInt:
		var n int
		switch v := val.(type) {
		case float64:
			n = int(v)
		case int:
			n = v
		case int64:
			n = int(v)
		default:
			return nil
		}
		if c.Min != nil && n < *c.Min {
			return fmt.Errorf("%w: min value %d", domain.ErrValidationFailed, *c.Min)
		}
		if c.Max != nil && n > *c.Max {
			return fmt.Errorf("%w: max value %d", domain.ErrValidationFailed, *c.Max)
		}

	case domain.AttributeTypeEnum:
		s, ok := val.(string)
		if !ok {
			return nil
		}
		valid := false
		for _, e := range c.Enum {
			if s == e {
				valid = true
				break
			}
		}
		if !valid {
			return fmt.Errorf("%w: value %q not in allowed enums %v", domain.ErrValidationFailed, s, c.Enum)
		}
	}

	return nil
}

var _ domain.SchemaValidator = (*MemoryValidator)(nil)
