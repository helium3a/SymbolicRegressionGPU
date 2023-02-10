#include "regression.cuh"

namespace cusr {

    using namespace std;
    using namespace program;
    using namespace fit;

    void RegressionEngine::fit(vector<vector<float>> &dataset, vector<float> &label) {
        this->dataset = dataset;
        this->label = label;
        cusr::program::set_constant_prob(this->p_constant);
        do_fit_init();

        clock_t iter_begin = clock();

        do_population_init();
        update_population_attributes();

        printf("%15s %15s %15s %15s %15s %15s\n",
               "gen", "best fit", "best len", "best dep", "max len", "max dep");
        printf("---------------------------------------------------");
        printf("---------------------------------------------------\n");

        printf("%15d %15.5f %15d %15d %15d %15d\n",
               0, best_program.fitness, best_program.length, best_program.depth, max_length_in_population,
               max_depth_in_population);

        int iter_times = 1;

        while (true) {
            gen_next_generation();
            update_population_attributes();

            printf("%15d %15.5f %15d %15d %15d %15d\n",
                   iter_times, best_program.fitness, best_program.length, best_program.depth, max_length_in_population,
                   max_depth_in_population);

            if (++iter_times >= generations || this->best_program.fitness <= this->stopping_criteria) {
                break;
            }
        }
        this->regress_time_in_sec = (float) (clock() - iter_begin) / (float) CLOCKS_PER_SEC;
        printf("---------------------------------------------------");
        printf("---------------------------------------------------\n");
        cout << "> iteration time: " << regress_time_in_sec << "s" << endl;
        cout << "> best program:   " << prefix_to_infix(best_program.prefix) << endl << endl << endl;

        if (use_gpu) {
            freeDataSetAndLabel(&device_dataset);
        }
    }

    void RegressionEngine::do_fit_init() {
        assert(!dataset.empty() && dataset.size() == label.size());

        this->variable_nums = dataset[0].size();

        if (use_gpu) {
            do_gpu_init();
        }
    }

    void RegressionEngine::do_population_init() {
        this->population.clear();

        // full initialize
        if (this->init_method == InitMethod::full) {
            for (int i = 0; i < population_size; i++) {
                int depth = gen_rand_int(init_depth.first, init_depth.second);
                this->population.emplace_back(*gen_full_init_program(depth, const_range, function_set, variable_nums));
            }
        }

        // growth initialize
        if (this->init_method == InitMethod::growth) {
            for (int i = 0; i < population_size; i++) {
                int depth = gen_rand_int(init_depth.first, init_depth.second);
                this->population.emplace_back(
                        *gen_growth_init_program(depth, const_range, function_set, variable_nums));
            }
        }

        // ramped half and half
        if (this->init_method == InitMethod::half_and_half) {
            // assert(population_size >= 2);
            int full_size = population_size / 2;
            int growth_size = population_size - full_size;

            for (int i = 0; i < full_size; i++) {
                int depth = gen_rand_int(init_depth.first, init_depth.second);
                this->population.emplace_back(*gen_full_init_program(depth, const_range, function_set, variable_nums));
            }

            for (int i = 0; i < growth_size; i++) {
                int depth = gen_rand_int(init_depth.first, init_depth.second);
                this->population.emplace_back(
                        *gen_growth_init_program(depth, const_range, function_set, variable_nums));
            }
        }

        if (use_gpu) {
            calculate_population_fitness_gpu();
        } else {
            calculate_population_fitness_cpu();
        }
    }

    Program RegressionEngine::do_mutation(Program &program) {
        Program ret;

        float rand_float = gen_rand_float(0, 1);

        if (rand_float < p_crossover) {
            int index = tournament_selection_cpu(population, tournament_size, parsimony_coefficient);
            ret = crossover_mutation(program, population[index]);
        } else if (rand_float < p_crossover + p_hoist_mutation) {
            ret = hoist_mutation(program);
        } else if (rand_float < p_crossover + p_hoist_mutation + p_point_mutation) {
            ret = point_mutation(program, function_set, const_range, variable_nums);
        } else if (rand_float < p_crossover + p_hoist_mutation + p_point_mutation + p_subtree_mutation) {
            int rand_int = gen_rand_int(init_depth.first, init_depth.second);
            ret = subtree_mutation(program, rand_int, const_range, function_set, variable_nums);
        } else if (rand_float <
                   p_crossover + p_hoist_mutation + p_point_mutation + p_subtree_mutation + p_point_replace) {
            ret = point_replace_mutation(program, function_set, const_range, variable_nums);
        } else {
            return program;
        }

        ret.depth = get_depth_of_prefix(ret.prefix);

        // hoist until the depth under the specified depth
        while (restrict_depth && ret.depth > max_program_depth) {
            ret = hoist_mutation(ret);
            ret.depth = get_depth_of_prefix(ret.prefix);
        }

        ret.length = ret.prefix.size();
        return ret;
    }

    void RegressionEngine::gen_next_generation() {
        vector<Program> next_gen;

        // elite strategy
        int best_fitness_index = 0;
        for (int i = 1; i < population_size; i++) {
            if (population[i].fitness < population[best_fitness_index].fitness) {
                best_fitness_index = i;
            }
        }

        next_gen.emplace_back(population[best_fitness_index]);

        // selection and do mutation
        for (int i = 1; i < population_size; i++) {
            int index = tournament_selection_cpu(population, tournament_size, parsimony_coefficient);
            next_gen.emplace_back(do_mutation(population[index]));
        }

        population.assign(next_gen.begin(), next_gen.end());

        // fitness evaluation
        if (use_gpu) {
            calculate_population_fitness_gpu();
        } else {
            calculate_population_fitness_cpu();
        }

    }

    void RegressionEngine::update_population_attributes() {

        int best_fitness_index = 0;
        int max_prefix_length = 0;
        int max_prefix_depth = 0;

        for (int i = 1; i < population_size; i++) {
            if (population[i].fitness < population[best_fitness_index].fitness) {
                best_fitness_index = i;
            }
            if (population[i].length > max_prefix_length) {
                max_prefix_length = population[i].length;
            }
            if (population[i].depth > max_prefix_depth) {
                max_prefix_depth = population[i].depth;
            }
        }

        this->best_program = population[best_fitness_index];
        this->max_length_in_population = max_prefix_length;
        this->max_depth_in_population = max_prefix_depth;
        this->best_program_in_each_gen.emplace_back(this->best_program);
    }

    void RegressionEngine::fit(vector<vector<float>> &dataset, vector<float> &label, string metric) {

        fit(dataset, label);

        // argsort all programs by their fitnesses
        vector<int> indices(population_size);
        iota(indices.begin(), indices.end(), 0);
        sort(indices.begin(), indices.end(),
        [this](int i, int j) { return this->population[i].fitness < this->population[j].fitness; });

        // TODO: calculate predictions of hall_of_fame programs(from best to worst)
        // TODO: check if use gpu or cpu to calculate
        vector<vector<float>> predictions(population_size, vector<float>(dataset.size()));
        for(int i=0; i<n_hall_of_fame; i++) {
            predict_cpu(&population[indices[i]], dataset, dataset.size(), this->metric, predictions[i]);
        }

        // TODO: calculate correlations between hall_of_fame programs(may add new metrics in the future, design the
        // code structure such that is easy to maintain!)
        // TODO: check metric type 'pearson' or 'spearman'
        vector<vector<float>> corr_matrix(n_hall_of_fame, vector<float>(n_hall_of_fame));
        for(int i=0; i<n_hall_of_fame-1; i++) {
            for(int j=i+1; j<n_hall_of_fame; j++) {
                corr_matrix[i][j] = i+j;// abs(cal_corr(predictions[indices[i]], predictions[indices[j]]));
            }
        }
        
        // TODO: select top n_components most uncorrelated programs from
        // population[indices[0]] ... population[indices[n_hall_of_fame-1]]
        unordered_set<int> excluded;
        int to_exclude;
        float max_corr;
        while(n_hall_of_fame - excluded.size() > n_components) {
            to_exclude = 0;
            max_corr = 0.0;
            for(int i=0; i<n_hall_of_fame-1; i++) {
                if(excluded.find(i) != excluded.end()) continue;
                for(int j=i+1; j<n_hall_of_fame; j++) {
                    if(excluded.find(j) != excluded.end()) continue;
                    if(corr_matrix[i][j] > max_corr) {
                        max_corr = corr_matrix[i][j];
                        to_exclude = j;
                    }
                    else if(corr_matrix[i][j] == max_corr && j > to_exclude) to_exclude = j; 
                }
            }
            excluded.insert(to_exclude);
        }

        // save top n_components programs to components
        for(int i=0; i<n_hall_of_fame; i++) {
            if(excluded.find(i)==excluded.end()) components.emplace_back(population[indices[i]]);
        }
    }

    void transform(vector<vector<float>> &dataset, vector<vector<float>> &new_dataset) {
        // TODO: check dataset.size()==new_dataset.size() and dataset.size() + n_components == new_dataset.size()
    }

    void RegressionEngine::calculate_population_fitness_cpu() {
        for (int i = 0; i < population_size; i++) {
            calculate_fitness_cpu(&population[i], dataset, label, dataset.size(), this->metric);
        }
    }

    void RegressionEngine::calculate_population_fitness_gpu() {
        int blockNum = (dataset.size() - 1) / THREAD_PER_BLOCK + 1;
        calculatePopulationFitness(this->device_dataset, blockNum, population, this->metric);
    }

    void RegressionEngine::do_gpu_init() {
        copyDatasetAndLabel(&device_dataset, dataset, label);
    }

    RegressionEngine::~RegressionEngine() {
        freeDataSetAndLabel(&this->device_dataset);
    }
}